package Market::Overlays::Fibonacci;

# =============================================================================
# Market::Overlays::Fibonacci
#
# Retroceso/extension de Fibonacci proyectado UNICAMENTE sobre el ultimo
# tramo YA CONFIRMADO (estable) del ZigZag EXTERNO, nunca sobre la rama
# "pendiente" (get_pending_external) que todavia se esta formando y puede
# seguir repintandose -- pedido explicito de la revision del ingeniero:
# "no puede ser desde la rama que esta todavia moviendose porque esa aun
# no es estable".
#
# El tramo estable es, por definicion, el segmento entre los DOS ULTIMOS
# pivotes de get_segments('external') (ambos ya confirmados). Direccion:
#   - ultimo pivote = H (el tramo fue L->H, alcista) -> retrocesos hacia
#     ABAJO desde el high: nivel(p) = high - (high-low)*p
#   - ultimo pivote = L (el tramo fue H->L, bajista) -> retrocesos hacia
#     ARRIBA desde el low:  nivel(p) = low  + (high-low)*p
#
# Niveles: retroceso estandar (0/23.6/38.2/50/61.8/78.6/100) + extension
# (127.2/161.8) como "zonas donde el precio puede reaccionar". Las lineas
# se dibujan desde el FIN del tramo estable hasta el borde derecho visible,
# proyectando hacia el precio futuro.
#
# NO calcula nada nuevo: es puro derivado de render-time de los segmentos ya
# calculados por Indicators::ZigZag (mismo patron que Overlays::ZigZag), asi
# que no hace falta un Indicators::Fibonacci.pm separado.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_fibonacci';
use constant COLOR      => '#b8860b';   # dorado, sin choque con la paleta ya usada
use constant COLOR_EXT  => '#c9a227';   # extension, mismo tono mas claro

use constant RETRACE_LEVELS   => (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);
use constant EXTENSION_LEVELS => (1.272, 1.618);

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source => $args{source},   # Indicators::ZigZag
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source} or return;

    my $segs = $src->get_segments('external');
    return unless $segs && @$segs >= 2;

    # Los DOS ULTIMOS pivotes CONFIRMADOS = el tramo estable. Se ignora a
    # proposito get_pending_external() -- esa es la rama aun inestable.
    my $a = $segs->[-2];
    my $b = $segs->[-1];
    return if $a->{price} == $b->{price};

    my $md = $src->get_market_data or return;
    my $active_arr = $md->get_data->{ $md->get_timeframe };
    return unless $active_arr && @$active_arr;
    my $last_vis = $md->last_index;
    return if $last_vis < 0;

    my $ia = $self->_ts_to_active_idx( $a->{ts}, $active_arr, $last_vis );
    my $ib = $self->_ts_to_active_idx( $b->{ts}, $active_arr, $last_vis );
    return if $ib < $ia;   # defensivo: el tramo debe ir hacia adelante en el tiempo

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    return if $ib > $off + $vb;

    my $up   = ( $b->{kind} eq 'H' );   # tramo L->H (alcista) si termina en H
    my $high = $up ? $b->{price} : $a->{price};
    my $low  = $up ? $a->{price} : $b->{price};
    my $range = $high - $low;
    return if $range <= 0;

    my $x_start = $scale->index_to_center_x($ib);
    $x_start = 0 if $x_start < 0;
    return if $x_start >= $plot_w;

    for my $p ( RETRACE_LEVELS, EXTENSION_LEVELS ) {
        my $price = $up ? ( $high - $range * $p ) : ( $low + $range * $p );
        next unless $scale->value_in_range($price);

        my $y        = $scale->value_to_y($price);
        my $is_ext   = ( $p > 1 );
        my $color    = $is_ext ? COLOR_EXT : COLOR;
        my $pct_text = sprintf( '%.1f%%', $p * 100 );

        $canvas->createLine( $x_start, $y, $plot_w, $y,
            -fill => $color,
            -dash => ( $is_ext ? [ 2, 4 ] : [ 5, 3 ] ),
            -width => ( $p == 0 || $p == 1 ) ? 1.5 : 1,
            -tags => [TAG] );

        my $tid = $canvas->createText( $plot_w - 4, $y,
            -text   => "$pct_text  " . sprintf( '%.2f', $price ),
            -anchor => 'e',
            -fill   => $color,
            -font   => 'TkDefaultFont 7 bold',
            -tags   => [TAG] );
        my @bb = $canvas->bbox($tid);
        if (@bb) {
            my $rid = $canvas->createRectangle( $bb[0]-2, $bb[1]-1, $bb[2]+2, $bb[3]+1,
                -fill => '#ffffff', -outline => $color, -tags => [TAG] );
            $canvas->lower( $rid, $tid );
        }
    }
}

# -----------------------------------------------------------------------------
# _ts_to_active_idx: identico criterio de busqueda binaria que ya usa
# Overlays::ZigZag::_ts_to_active_idx (duplicado localmente a proposito --
# cada overlay de este proyecto es autosuficiente, mismo patron ya
# establecido en el resto del modulo Overlays).
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