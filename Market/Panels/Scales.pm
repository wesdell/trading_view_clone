package Market::Panels::Scales;

# =============================================================================
# Market::Panels::Scales
# Responsabilidad: transformacion entre coordenadas de datos y coordenadas
# de pantalla. Cada panel tiene su propia instancia (eje Y independiente).
# El eje X es comun en valores logicos (indice) pero cada panel calcula su
# propio mapeo de pixeles segun su ancho.
#
# REGLA CRITICA: NUNCA mezclar coordenadas de datos con coordenadas de
# pantalla. Todas las conversiones pasan por esta clase.
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);

# -----------------------------------------------------------------------------
# new
# Parametros aceptados:
#   canvas_w, canvas_h     - dimensiones totales del canvas (pixeles)
#   price_scale_w          - ancho del area de regleta a la derecha (pixeles)
#   visible_bars           - cantidad de velas visibles
#   offset                 - indice de la primera vela visible
#   min_val, max_val       - rango del eje Y (datos)
#   padding_top, padding_bot - margenes verticales del plot (pixeles)
#   last_close / last_atr_val - opcional: valor del ultimo precio/ATR visible
# -----------------------------------------------------------------------------
sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas_w      => $args{canvas_w}      // 800,
        canvas_h      => $args{canvas_h}      // 400,
        price_scale_w => $args{price_scale_w} // 90,
        visual_offset => $args{visual_offset} // 0,
        visible_bars  => $args{visible_bars}  // 100,
        offset        => $args{offset}        // 0,
        min_val       => $args{min_val}       // 0,
        max_val       => $args{max_val}       // 1,
        padding_top   => $args{padding_top}   // 10,
        padding_bot   => $args{padding_bot}   // 10,
        %args,
    };
    bless $self, $class;
    return $self;
}

# Ancho del area de plot (sin regleta)
sub _plot_w {
    my ($self) = @_;
    return $self->{canvas_w} - $self->{price_scale_w};
}

# Alto del area de plot (sin paddings ni eje temporal)
sub _plot_h {
    my ($self) = @_;
    return $self->{canvas_h} - $self->{padding_top} - $self->{padding_bot};
}

# Y maximo (inferior) del area de plot
sub _plot_y_bottom {
    my ($self) = @_;
    return $self->{padding_top} + $self->_plot_h;
}

# Y minimo (superior) del area de plot
sub _plot_y_top {
    my ($self) = @_;
    return $self->{padding_top};
}

# -----------------------------------------------------------------------------
# index_to_x
# indice -> X borde izquierdo de la barra
# -----------------------------------------------------------------------------
sub index_to_x {
    my ( $self, $index ) = @_;
    my $bar_w = $self->_plot_w / $self->{visible_bars};
    return ( $index - $self->{offset} ) * $bar_w;
}

# -----------------------------------------------------------------------------
# x_to_index
# X -> indice entero (vela bajo el cursor)
# -----------------------------------------------------------------------------
sub x_to_index {
    my ( $self, $x ) = @_;

    my $bar_w = $self->_plot_w / $self->{visible_bars};

    my $idx = int( ( $x / $bar_w ) + $self->{offset} - $self->{visual_offset} );

    return $idx;
}

# -----------------------------------------------------------------------------
# x_to_index_float
# X -> indice fraccional (mas preciso para interaccion)
# -----------------------------------------------------------------------------
sub x_to_index_float {
    my ( $self, $x ) = @_;
    my $bar_w = $self->_plot_w / $self->{visible_bars};
    return ( $x / $bar_w ) + $self->{offset};
}

# -----------------------------------------------------------------------------
# index_to_center_x
# indice -> X del centro de la barra
# -----------------------------------------------------------------------------
sub index_to_center_x {
    my ( $self, $idx ) = @_;

    my $bar_w = $self->_plot_w / $self->{visible_bars};

    return ( ( $idx - $self->{offset} + $self->{visual_offset} ) * $bar_w ) +
      ( $bar_w / 2 );
}

# -----------------------------------------------------------------------------
# value_to_y
# valor (precio o ATR) -> Y pantalla. CLAMPEADO al area de plot para que
# nada se salga visualmente del panel.
# -----------------------------------------------------------------------------
sub value_to_y {
    my ( $self, $value ) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    return $self->{padding_top} if $range == 0;

    my $n = ( $value - $self->{min_val} ) / $range;
    $n = 0 if $n < 0;
    $n = 1 if $n > 1;

    return $self->{padding_top} + $self->_plot_h * ( 1 - $n );
}

# -----------------------------------------------------------------------------
# value_to_y_raw
# Igual que value_to_y pero SIN clamp: devuelve la Y aunque caiga fuera
# del area de plot. Util para detectar si un valor esta fuera de pantalla.
# -----------------------------------------------------------------------------
sub value_to_y_raw {
    my ( $self, $value ) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    return $self->{padding_top} if $range == 0;
    my $n = ( $value - $self->{min_val} ) / $range;
    return $self->{padding_top} + $self->_plot_h * ( 1 - $n );
}

# -----------------------------------------------------------------------------
# value_in_range
# Devuelve 1 si el valor esta dentro del rango visible Y.
# -----------------------------------------------------------------------------
sub value_in_range {
    my ( $self, $value ) = @_;
    return ( $value >= $self->{min_val} && $value <= $self->{max_val} ) ? 1 : 0;
}

# -----------------------------------------------------------------------------
# y_to_value
# Y -> valor (inversa de value_to_y).
# Util para el crosshair.
# -----------------------------------------------------------------------------
sub y_to_value {
    my ( $self, $y ) = @_;
    my $plot_h = $self->_plot_h;
    return $self->{min_val} if $plot_h == 0;
    my $n = 1 - ( $y - $self->{padding_top} ) / $plot_h;
    $n = 0 if $n < 0;
    $n = 1 if $n > 1;
    return $self->{min_val} + $n * ( $self->{max_val} - $self->{min_val} );
}

# -----------------------------------------------------------------------------
# _draw_y_scale
# Dibuja la escala vertical (eje Y derecho) + grilla horizontal.
#
# Estrategia:
#   1. Buscar un paso "bonito" para que queden ~10 marcas visibles.
#   2. Dibujar grilla tenue desde el primer multiplo del paso >= min_val.
#   3. Etiquetas numericas centradas en el area de regleta.
# -----------------------------------------------------------------------------
sub _draw_y_scale {
    my ( $self, $canvas ) = @_;

    my $x_sep = $self->_plot_w;
    my $x_end = $self->{canvas_w};
    my $range = $self->{max_val} - $self->{min_val};
    return if $range <= 0;

    my $min_label_spacing = 16;               # mínimo 16px entre etiquetas
    my $plot_h            = $self->_plot_h;   # altura real del panel en píxeles
    my $target_lines      = int( $plot_h / $min_label_spacing );
    $target_lines = 2 if $target_lines < 2;
    my $raw_step = $range / $target_lines;

    # Tabla de pasos "bonitos" (potencias de 2, 5, 10) con buena densidad
    my @nice = (
        0.001, 0.002, 0.0025, 0.005, 0.01, 0.02, 0.025, 0.05,
        0.1,   0.2,   0.25,   0.5,   1,    2,    2.5,   5,
        10,    20,    25,     50,    100,  200,  250,   500,
        1000,  2000,  2500,   5000,
    );
    my $step = $nice[-1];
    for my $m (@nice) {
        if ( $m >= $raw_step ) { $step = $m; last; }
    }

    # Decimales adaptativos al tamano del paso
    my $decimals =
        ( $step >= 10 )   ? 0
      : ( $step >= 1 )    ? 1
      : ( $step >= 0.1 )  ? 2
      : ( $step >= 0.01 ) ? 3
      :                     4;
    my $fmt = "%.${decimals}f";

    # Primer nivel >= min_val alineado al paso
    my $first = int( $self->{min_val} / $step ) * $step;
    $first += $step if ( $first + 1e-9 ) < $self->{min_val};
    $first = sprintf( '%.10f', $first ) + 0;

    # Fondo blanco del area de regleta
    $canvas->createRectangle(
        $x_sep, 0, $x_end, $self->{canvas_h},
        -fill    => '#ffffff',
        -outline => '#ffffff',
        -tags    => ['scale_bg'],
    );

    # Linea separadora vertical (regleta vs plot)
    $canvas->createLine(
        $x_sep, 0, $x_sep, $self->{canvas_h},
        -fill  => '#c9cdd7',
        -width => 1,
        -tags  => ['scale_border'],
    );

    # Niveles + etiquetas
    my $level = $first;
    while ( $level <= $self->{max_val} + 1e-9 ) {
        my $y = $self->value_to_y($level);

        # Grilla tenue (solo en el area de plot)
        $canvas->createLine(
            0, $y, $x_sep, $y,
            -fill  => '#e0e3eb',
            -width => 1,
            -tags  => ['scale_grid'],
        );

        # Etiqueta numerica centrada en la regleta
        $canvas->createText(
            $x_sep + ( $x_end - $x_sep ) / 2, $y,
            -text   => sprintf( $fmt, $level ),
            -fill   => '#363a45',
            -anchor => 'center',
            -font   => 'TkFixedFont 8',
            -tags   => ['scale_label'],
        );

        $level += $step;
        $level = sprintf( '%.10f', $level ) + 0;
    }
}

1;
