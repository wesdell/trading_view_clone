package Market::Overlays::DemoOverlay;

# =============================================================================
# Market::Overlays::DemoOverlay
#
# *** ARCHIVO DE VALIDACION TEMPORAL - Etapa 2 (Fase 2) ***
# Unico proposito: confirmar que el contrato de Overlay (tag + render)
# funciona correctamente integrado en ChartEngine::render, sincronizado
# con scroll y zoom (horizontal Y vertical), y reutilizando el mismo
# objeto Scales que ya usa PricePanel -- sin crear ninguna escala propia.
#
# Dibuja dos elementos minimos que ejercitan ambos ejes del Scale:
#   1. Una linea horizontal a un PRECIO fijo (prueba value_to_y /
#      value_in_range -- el eje vertical).
#   2. Una linea vertical en un INDICE de vela fijo (prueba
#      index_to_center_x y el culling por offset/visible_bars, igual
#      que ya hace PricePanel::draw_time_axis -- el eje horizontal).
#
# Se debe ELIMINAR (o reemplazar por Liquidity.pm / SMC_Structures.pm)
# una vez validada la arquitectura de Overlays, antes de la Etapa 8.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_demo';

sub new {
    my ($class, %args) = @_;
    my $self = {
        price        => $args{price}        // 0,   # nivel de precio FIJO a dibujar
        marker_index => $args{marker_index}  // 0,   # indice de vela FIJO a marcar
        color        => $args{color}         // '#787b86',
        marker_color => $args{marker_color}  // '#ff9800',
    };
    bless $self, $class;
    return $self;
}

sub tag {
    return TAG;
}

# -----------------------------------------------------------------------------
# render
# Se auto-limpia con su propio tag al inicio (mismo patron que
# PricePanel/ATRPanel::render), luego dibuja solo lo que cae dentro de
# rango segun la escala compartida.
# -----------------------------------------------------------------------------
sub render {
    my ($self, $canvas, $scale) = @_;

    $canvas->delete(TAG);

    # --- Eje vertical: linea de precio fijo (prueba value_to_y) ---
    if ( $scale->value_in_range($self->{price}) ) {
        my $y     = $scale->value_to_y($self->{price});
        my $x_end = $scale->_plot_w;

        $canvas->createLine(
            0, $y, $x_end, $y,
            -fill  => $self->{color},
            -dash  => [ 6, 4 ],
            -width => 1,
            -tags  => [ TAG ],
        );
        $canvas->createText(
            4, $y - 8,
            -text   => sprintf( 'DEMO %.2f', $self->{price} ),
            -fill   => $self->{color},
            -anchor => 'nw',
            -font   => 'TkFixedFont 7',
            -tags   => [ TAG ],
        );
    }

    # --- Eje horizontal: marcador vertical en indice fijo (prueba
    #     index_to_center_x + culling por offset/visible_bars, igual
    #     convencion que draw_time_axis) ---
    my $idx = $self->{marker_index};
    if ( $idx >= $scale->{offset} && $idx <= $scale->{offset} + $scale->{visible_bars} ) {
        my $x = $scale->index_to_center_x($idx);
        $canvas->createLine(
            $x, 0, $x, $scale->{canvas_h},
            -fill  => $self->{marker_color},
            -dash  => [ 2, 2 ],
            -width => 1,
            -tags  => [ TAG ],
        );
    }
}

1;