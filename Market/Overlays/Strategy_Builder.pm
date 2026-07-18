package Market::Overlays::Strategy_Builder;

# =============================================================================
# Market::Overlays::Strategy_Builder  (Tabla 1 del PDF, 2a fase)
# Renderiza en el Canvas de Tk lo YA calculado por Indicators::Strategy_Builder
# (separacion estricta calculo/render). Solo dibuja el RANGO VISIBLE. Sub-toggles
# independientes por componente. No calcula nada.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_strategy';
# Sub-tag SOLO de las ZONAS (rectangulos Supply/Demand) que deben quedar DETRAS
# de las velas. ChartEngine las baja bajo el tag 'candle' tras dibujar el overlay
# (mismo patron que smc_fvg_zone/smc_ob_zone). Las lineas/senales conservan TAG y
# permanecen AL FRENTE. El borrado por (in)visibilidad sigue usando TAG.
use constant TAG_ZONE => 'strategy_zone';
use constant {
    C_UP   => '#26a69a',   # alcista
    C_DOWN => '#ef5350',   # bajista
    C_RF   => '#42a5f5',   # range filter (color unico antiguo; ya no se usa)
    C_RF_UP   => '#00EFA0',   # Range Filter alcista  (verde/turquesa, estilo TradingView)
    C_RF_DOWN => '#FF0080',   # Range Filter bajista  (magenta/rosa,  estilo TradingView)
    C_DEM  => '#00AEEF',   # Demand: azul/celeste (estilo BigBeluga)
    C_SUP  => '#FF8C00',   # Supply: naranja       (estilo BigBeluga)
    C_SIG  => '#ffb300',   # senal
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        source        => $args{source},
        show_supertrend => $args{show_supertrend} // 1,
        show_halftrend  => $args{show_halftrend}  // 1,
        show_rangefilter=> $args{show_rangefilter}// 1,
        show_supply     => $args{show_supply}     // 1,
        show_demand     => $args{show_demand}     // 1,
        show_signals    => $args{show_signals}    // 1,
        _plot_w         => undef,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ($self, $flag, $val) = @_;
    $self->{$flag} = $val ? 1 : 0 if exists $self->{$flag};
}

sub render {
    my ($self, $canvas, $scale, $placer) = @_;
    my $src = $self->{source} or return;
    $self->{_plot_w} = $scale->_plot_w;

    # IDEMPOTENCIA (contrato de OverlayManager, igual que SMC_Structures y
    # Liquidity): borrar los items del frame ANTERIOR por el tag general ANTES de
    # redibujar. Sin esto, cada zoom/pan/scroll/Replay acumulaba rectangulos y
    # lineas encima de los previos -> zonas duplicadas/fragmentadas/desplazadas y
    # colores Supply/Demand mezclados. NO toca el estado matematico (las zonas
    # viven en el indicador); solo limpia el Canvas. Redibujar N veces deja
    # exactamente los mismos objetos.
    $canvas->delete(TAG);

    # SuperTrend: linea que ROMPE en cada flip (verde en alza / roja en baja, sin
    # diagonal que las una), igual que TradingView. HalfTrend: bicolor continua.
    $self->_render_line($canvas, $scale, $src->get_supertrend,  'dir', 1) if $self->{show_supertrend};
    $self->_render_line($canvas, $scale, $src->get_halftrend,   'dir', 0) if $self->{show_halftrend};
    $self->_render_rf($canvas, $scale, $src->get_rangefilter)          if $self->{show_rangefilter};
    $self->_render_zones($canvas, $scale, $src->get_demand_zones, C_DEM) if $self->{show_demand};
    $self->_render_zones($canvas, $scale, $src->get_supply_zones, C_SUP) if $self->{show_supply};
    $self->_render_signals($canvas, $scale, $src)                     if $self->{show_signals};
}

# rango visible de indices, acotado a lo procesado y al puntero de replay
sub _visible_range {
    my ($self, $scale, $n) = @_;
    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};
    my $s = int($off);    $s = 0 if $s < 0;
    my $e = int($off) + $vb + 1;
    $e = $n - 1 if $e > $n - 1;
    return ($s, $e);
}

# linea coloreada por direccion (SuperTrend / HalfTrend). Se dibuja como
# POLILINEAS por tramo de color CONSTANTE (menos objetos Canvas que N segmentos).
sub _render_line {
    my ($self, $canvas, $scale, $arr, $dirkey, $break_flip) = @_;
    return unless $arr && @$arr;
    my $plot_w = $scale->_plot_w;
    my ($s, $e) = $self->_visible_range($scale, scalar @$arr);
    return if $e <= $s;
    my @co; my $curcol;
    my $flush = sub { $canvas->createLine(@co, -fill=>$curcol, -width=>2, -tags=>[TAG]) if @co >= 4; @co = (); };
    my ($px, $py);
    for my $i ($s .. $e) {
        my $v = $arr->[$i]{value};
        if (!defined $v) { $flush->(); ($px,$py)=(undef,undef); next; }
        my $x = $scale->index_to_center_x($i);
        if ($x < -0.5 || $x > $plot_w + 0.5) { $flush->(); ($px,$py)=(undef,undef); next; }
        my $y = $scale->value_to_y($v);
        my $col = ($arr->[$i]{$dirkey} >= 0) ? C_UP : C_DOWN;
        # Flip de tendencia (cambio de color): cerrar el tramo actual. En modo
        # BREAK (SuperTrend, estilo TradingView) se arranca un tramo nuevo SIN unir
        # -> la verde termina y la roja empieza aparte. En modo continuo (HalfTrend)
        # se enlaza con el punto previo, ya pintado con el color NUEVO.
        if (@co && $col ne $curcol) {
            $flush->();
            push @co, $px, $py if !$break_flip && defined $px;
        }
        $curcol = $col;   # FIX: actualizar SIEMPRE el color del tramo. Antes era
                          # `unless @co`, y como tras el flush se reinsertaba el
                          # punto previo, @co nunca quedaba vacio y el color se
                          # congelaba en el de la 1a vela -> linea MONOCROMA.
        push @co, $x, $y; ($px,$py)=($x,$y);
    }
    $flush->();
}

# Range Filter: polilinea unica (un color) por tramo continuo.
sub _render_rf {
    my ($self, $canvas, $scale, $arr) = @_;
    return unless $arr && @$arr;
    my $plot_w = $scale->_plot_w;
    my ($s, $e) = $self->_visible_range($scale, scalar @$arr);
    return if $e <= $s;
    # BICOLOR por DIRECCION confirmada, igual que Range Filter [DW] de TradingView:
    # verde/turquesa cuando el filtro sube (dir>=0) y magenta/rosa cuando baja
    # (dir<0). La direccion la fija el propio algoritmo en `_calc_rangefilter`
    # (dir = filt>prev?+1:filt<prev?-1:prev_dir), asi que el estado se MANTIENE en
    # los tramos planos y el color cambia EXACTAMENTE en la vela donde el filtro
    # confirma el nuevo sentido (sin recolorear velas anteriores, sin futuro).
    # Un item de Canvas por cada racha continua de la misma direccion; en el flip
    # se comparte el ultimo punto para que la linea quede continua (sin huecos ni
    # diagonales falsas: la RF es continua, velas contiguas). Mismo tag general.
    my @co; my $curcol; my ($px, $py);
    my $flush = sub { $canvas->createLine(@co, -fill=>$curcol, -width=>1, -tags=>[TAG]) if @co >= 4; @co = (); };
    for my $i ($s .. $e) {
        my $v = $arr->[$i]{value};
        if (!defined $v) { $flush->(); ($px,$py)=(undef,undef); next; }
        my $x = $scale->index_to_center_x($i);
        if ($x < -0.5 || $x > $plot_w + 0.5) { $flush->(); ($px,$py)=(undef,undef); next; }
        my $y = $scale->value_to_y($v);
        my $col = (($arr->[$i]{dir} // 0) >= 0) ? C_RF_UP : C_RF_DOWN;
        if (@co && $col ne $curcol) { $flush->(); push @co, $px, $py if defined $px; }
        $curcol = $col;
        push @co, $x, $y; ($px,$py)=($x,$y);
    }
    $flush->();
}

# zonas Supply/Demand: rectangulo desde su creacion hasta el borde; mitigada mas
# tenue; invalidada no se dibuja.
sub _render_zones {
    my ($self, $canvas, $scale, $zones, $col) = @_;
    return unless $zones && @$zones;
    my $plot_w = $scale->_plot_w;
    my $last   = $self->_last_index($scale);
    for my $z (@$zones) {
        next if $z->{state} eq 'invalidated';
        next unless $scale->value_in_range($z->{zone_low}) || $scale->value_in_range($z->{zone_high})
                 || ($z->{zone_low} < $scale->{min_val} && $z->{zone_high} > $scale->{max_val});
        # Extension a la derecha: ACTIVA -> hasta la ultima vela (borde derecho
        # actual); MITIGADA -> solo hasta su vela de mitigacion (no mas alla).
        # Nunca antes del origen. (Invalidada no se dibuja.)
        my $end_i = ($z->{state} eq 'active') ? $last
                  : defined $z->{mitig_at}   ? $z->{mitig_at}
                  : defined $z->{invalid_at} ? $z->{invalid_at}
                  :                            $last;
        my $x1 = $scale->index_to_center_x($z->{idx});
        my $x2 = $scale->index_to_center_x($end_i);
        $x1 = 0 if $x1 < 0; $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;
        my $yt = $scale->value_to_y($z->{zone_high});
        my $yb = $scale->value_to_y($z->{zone_low});
        next if $yb - $yt < 1;
        my $op = ($z->{state} eq 'mitigated') ? 0.10 : 0.20;
        # ID ESTABLE por zona = tipo + timestamp de ORIGEN (dato real, no la vista):
        # se reconstruye identico en zoom/pan/Replay/redibujado. Tags: general (TAG)
        # + z-order (TAG_ZONE, detras de las velas) + especifico (sd_<tipo>_<ts>).
        my $zid = 'sd_' . $z->{kind} . '_' . $z->{ts};
        # Borde a COLOR PLENO (naranja Supply / azul Demand) + relleno claro -> se
        # distinguen con claridad aun solapando parcialmente.
        $canvas->createRectangle($x1,$yt,$x2,$yb,
            -fill=>_mix($col,$op), -outline=>$col, -width=>1, -tags=>[TAG, TAG_ZONE, $zid]);
        # Etiqueta SUPPLY/DEMAND (+ volumen) en el origen de la zona.
        my $lbl = uc($z->{kind}) . (defined $z->{volume} ? " $z->{volume}" : '');
        $canvas->createText($x1 + 2, $yt + 6, -text=>$lbl, -anchor=>'w',
            -fill=>$col, -font=>'TkDefaultFont 6 bold', -tags=>[TAG, $zid]);
    }
}

# senales entry/exit: marcador en la vela
sub _render_signals {
    my ($self, $canvas, $scale, $src) = @_;
    my $sigs = $src->get_signals or return;
    my ($s, $e) = $self->_visible_range($scale, $self->_last_index($scale) + 1);
    for my $sg (@$sigs) {
        next if $sg->{index} < $s || $sg->{index} > $e;
        my $cd = $src->get_market_data ? $src->get_market_data->get_candle($sg->{index}) : undef;
        next unless $cd;
        my $price = ($sg->{kind} eq 'entry') ? $cd->{low} : $cd->{high};
        next unless $scale->value_in_range($price);
        my $x = $scale->index_to_center_x($sg->{index});
        my $y = $scale->value_to_y($price);
        my $dy = ($sg->{kind} eq 'entry') ? 8 : -8;
        $canvas->createPolygon($x-4,$y+$dy, $x+4,$y+$dy, $x,$y,
            -fill=>C_SIG, -outline=>C_SIG, -tags=>[TAG]);
    }
}

sub _last_index {
    my ($self, $scale) = @_;
    my $src = $self->{source};
    my $md  = $src->get_market_data;
    return $md ? $md->last_index : (scalar(@{ $src->get_supertrend }) - 1);
}

# mezcla color hex con blanco por opacidad (igual criterio que SMC overlay)
sub _mix {
    my ($hex, $op) = @_;
    my ($r,$g,$b) = map { hex } ($hex =~ /^#(..)(..)(..)$/);
    $r = int($r*$op + 255*(1-$op));
    $g = int($g*$op + 255*(1-$op));
    $b = int($b*$op + 255*(1-$op));
    return sprintf('#%02x%02x%02x', $r, $g, $b);
}

1;
