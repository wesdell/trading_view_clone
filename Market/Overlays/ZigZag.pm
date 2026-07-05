package Market::Overlays::ZigZag;

# =============================================================================
# Market::Overlays::ZigZag
#
# Dibuja los dos zigzags sobre el canvas de precio.
#
# MULTI-TEMPORALIDAD
#     Los pivotes almacenan timestamps (ts), no indices fijos de 1m.
#     En render-time, cada ts se convierte al indice correcto del array
#     de la TF activa via busqueda binaria. De esta forma el zigzag se
#     dibuja correctamente en todas las temporalidades (1m, 5m, 15m, 1h,
#     etc.) sin requerir recalculo del indicador.
#
# COLORES (replica exacta de la imagen de referencia)
#     Interno : segmento alcista (L->H) = verde (#26a69a)
#               segmento bajista (H->L) = rojo  (#ef5350)
#     Externo : siempre azul (#1e88e5), trazo mas grueso
# =============================================================================

use strict;
use warnings;

use constant TAG    => 'overlay_zigzag';
use constant C_UP   => '#26a69a';   # verde
use constant C_DOWN => '#ef5350';   # rojo
use constant C_EXT  => '#1e88e5';   # azul

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source        => $args{source},
        show_internal => $args{show_internal} // 1,
        show_external => $args{show_external} // 1,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ( $self, $key, $val ) = @_;
    $self->{$key} = $val if exists $self->{$key};
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source} or return;

    # Obtener el market_data del indicador para conversion ts->indice
    my $md = $src->get_market_data or return;

    # Array activo de la TF que el usuario esta viendo (1m, 5m, 15m, 1h, ...)
    my $active_arr = $md->get_data->{ $md->get_timeframe };
    return unless $active_arr && @$active_arr;

    # Limite visible (respeta replay boundary)
    my $last_visible = $md->last_index;
    return if $last_visible < 0;

    if ($self->{show_internal}) {
        $self->_render_zz(
            $canvas, $scale,
            $src->get_segments('internal'),
            $active_arr, $last_visible, 'internal',
        );
    }

    if ($self->{show_external}) {
        my @ext_draw = @{ $src->get_segments('external') };
        if ($src->can('get_pending_external')) {
            my $pending = $src->get_pending_external;
            push @ext_draw, $pending if $pending;
        }
        $self->_render_zz(
            $canvas, $scale,
            \@ext_draw,
            $active_arr, $last_visible, 'external',
        );
    }
}

# -----------------------------------------------------------------------------
# _render_zz: dibuja los segmentos de un zigzag.
#
# Para cada pivote, convierte su ts al indice del array activo via
# busqueda binaria (_ts_to_active_idx). Si el indice cae fuera de la
# ventana visible (offset .. offset+visible_bars) el segmento se omite
# a menos que uno de sus extremos sea visible (renderizacion parcial
# correcta para segmentos que cruzan el borde de la ventana).
# -----------------------------------------------------------------------------
sub _render_zz {
    my ( $self, $canvas, $scale, $segs, $active_arr, $last_vis, $which ) = @_;
    return unless $segs && @$segs >= 2;

    my $off      = $scale->{offset};
    my $vb       = $scale->{visible_bars};
    my $is_ext   = ($which eq 'external');
    my $width    = $is_ext ? 2 : 1;

    for my $k ( 0 .. $#$segs - 1 ) {
        my $a = $segs->[$k];
        my $b = $segs->[$k + 1];

        # Convertir timestamps a indices del array activo
        my $ia = $self->_ts_to_active_idx($a->{ts}, $active_arr, $last_vis);
        my $ib = $self->_ts_to_active_idx($b->{ts}, $active_arr, $last_vis);

        # Visible si el rango de indices del segmento [min(ia,ib), max(ia,ib)]
        # se superpone con la ventana [off, off+vb]. Esto cubre tanto el caso
        # en que uno de los extremos cae dentro como el caso en que el
        # segmento entero (ambos extremos fuera, uno a cada lado) atraviesa
        # la ventana -- antes se perdian los segmentos largos (tipico del
        # externo, Length=150) al hacer zoom a una ventana mas angosta que
        # el propio segmento.
        my ( $idx_lo, $idx_hi ) = $ia <= $ib ? ( $ia, $ib ) : ( $ib, $ia );
        next if $idx_hi < $off || $idx_lo > $off + $vb;

        # Mismo criterio para el precio: visible si el rango de precio del
        # segmento se superpone con [min_val, max_val], no solo si alguno
        # de los dos extremos cae exactamente dentro (un segmento inclinado
        # puede tener ambos extremos fuera del rango vertical y aun asi
        # cruzar la zona visible cuando hay zoom vertical manual).
        my ( $p_lo, $p_hi ) = $a->{price} <= $b->{price}
            ? ( $a->{price}, $b->{price} ) : ( $b->{price}, $a->{price} );
        next if $p_hi < $scale->{min_val} || $p_lo > $scale->{max_val};

        my $x1 = $scale->index_to_center_x($ia);
        my $y1 = $scale->value_to_y($a->{price});
        my $x2 = $scale->index_to_center_x($ib);
        my $y2 = $scale->value_to_y($b->{price});

        my $color;
        if ($is_ext) {
            $color = C_EXT;
        } else {
            # H->L = bajista (rojo), L->H = alcista (verde)
            $color = ($a->{kind} eq 'H') ? C_DOWN : C_UP;
        }

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => $width,
            -tags  => [TAG],
        );
    }
}

# -----------------------------------------------------------------------------
# _ts_to_active_idx: busqueda binaria del indice cuyo ts es el mas
# cercano (pero no mayor) a ts_target en el array activo de la TF
# actual. Respeta last_vis para no mostrar velas futuras en replay.
# -----------------------------------------------------------------------------
sub _ts_to_active_idx {
    my ($self, $ts_target, $arr, $last_vis) = @_;

    my ($lo, $hi) = (0, $last_vis);
    return 0 if $hi < 0;
    return 0 if $arr->[0]{ts} > $ts_target;
    return $last_vis if $arr->[$last_vis]{ts} <= $ts_target;

    my $found = 0;
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($arr->[$mid]{ts} <= $ts_target) {
            $found = $mid;
            $lo = $mid + 1;
        } else {
            $hi = $mid - 1;
        }
    }
    return $found;
}

1;