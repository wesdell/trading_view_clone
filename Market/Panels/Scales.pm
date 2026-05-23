package Market::Panels::Scales;

# ==============================================================================
# Market::Panels::Scales
# Responsabilidad: Transformaciones entre espacio de datos y espacio de pixels.
# Eje X compartido entre paneles; eje Y independiente por panel.
# NUNCA mezclar coordenadas de datos con coordenadas de pantalla.
# ==============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas_w     => $args{canvas_w}     // 1200,
        canvas_h     => $args{canvas_h}     // 400,
        scale_w      => $args{scale_w}      // 70,
        visible_bars => $args{visible_bars} // 200,
        offset       => $args{offset}       // 0,
        y_min        => $args{y_min}        // 0,
        y_max        => $args{y_max}        // 1,
        padding_top  => $args{padding_top}  // 10,
        padding_bot  => $args{padding_bot}  // 20,
    };
    bless $self, $class;
    return $self;
}

# --- Helpers internos de dimension ---

sub _chart_w {
    my ($self) = @_;
    return $self->{canvas_w} - $self->{scale_w};
}

sub _chart_h {
    my ($self) = @_;
    return $self->{canvas_h} - $self->{padding_top} - $self->{padding_bot};
}

# ------------------------------------------------------------------------------
# index_to_x
# Convierte indice de vela -> coordenada X (borde izquierdo de la vela).
# ------------------------------------------------------------------------------
sub index_to_x {
    my ($self, $index) = @_;

    my $usable_width =
        $self->{canvas_w} - $self->{scale_w};

    my $bar_width =
        $usable_width / $self->{visible_bars};

    return ($index - $self->{offset}) * $bar_width;
}

# ------------------------------------------------------------------------------
# index_to_center_x
# Devuelve el centro horizontal de una vela en pixeles.
# ------------------------------------------------------------------------------
sub index_to_center_x {
    my ($self, $index) = @_;

    my $usable_width =
        $self->{canvas_w} - $self->{scale_w};

    my $bar_width =
        $usable_width / $self->{visible_bars};

    return (
        ($index - $self->{offset}) * $bar_width
    ) + ($bar_width / 2);
}

# ------------------------------------------------------------------------------
# x_to_index
# Convierte coordenada X -> indice entero de vela.
# ------------------------------------------------------------------------------
sub x_to_index {
    my ($self, $x) = @_;

    my $usable_width =
        $self->{canvas_w} - $self->{scale_w};

    my $bar_width =
        $usable_width / $self->{visible_bars};

    return int(
        ($x / $bar_width)
        + $self->{offset}
    );
}

# ------------------------------------------------------------------------------
# x_to_index_float
# Convierte coordenada X -> indice continuo (mayor precision para interaccion).
# ------------------------------------------------------------------------------
sub x_to_index_float {
    my ($self, $x) = @_;

    my $usable_width =
        $self->{canvas_w} - $self->{scale_w};

    my $bar_width =
        $usable_width / $self->{visible_bars};

    return (
        $x / $bar_width
    ) + $self->{offset};
}

# ------------------------------------------------------------------------------
# value_to_y
# Convierte valor de datos (precio/indicador) -> coordenada Y en pixels.
# Y crece hacia abajo en pantalla; valores altos = Y pequena.
# ------------------------------------------------------------------------------
sub value_to_y {
    my ($self, $value) = @_;
    my $range = $self->{y_max} - $self->{y_min};
    return $self->{padding_top} if $range == 0;
    my $ratio = ($self->{y_max} - $value) / $range;
    return $self->{padding_top} + $ratio * $self->_chart_h();
}

# ------------------------------------------------------------------------------
# y_to_value
# Convierte coordenada Y en pixels -> valor de datos. Inversa de value_to_y.
# ------------------------------------------------------------------------------
sub y_to_value {
    my ($self, $y) = @_;
    my $range = $self->{y_max} - $self->{y_min};
    return $self->{y_min} if $range == 0;
    my $ratio = ($y - $self->{padding_top}) / $self->_chart_h();
    return $self->{y_max} - $ratio * $range;
}

# ------------------------------------------------------------------------------
# _bar_width  (privado)
# Ancho en pixels de una vela segun la ventana visible actual.
# ------------------------------------------------------------------------------
sub _bar_width {
    my ($self) = @_;
    return $self->_chart_w() / $self->{visible_bars};
}

# ------------------------------------------------------------------------------
# _draw_y_scale
# Dibuja la escala vertical derecha con etiquetas de precio/valor.
# Parametros:
#   $canvas : widget Tk::Canvas
#   $fmt    : formato sprintf para etiquetas (default '%.2f')
#   $tag    : tag Tk para agrupar elementos (default 'yscale')
# ------------------------------------------------------------------------------
sub _draw_y_scale {
    my ($self, $canvas, $fmt, $tag) = @_;
    $fmt //= '%.2f';
    $tag //= 'yscale';
    $canvas->delete($tag);

    my $x_left = $self->_chart_w();
    my $range  = $self->{y_max} - $self->{y_min};
    return if $range <= 0;

    # Calcular paso bonito con guard contra log(0)
    my $num_labels = 6;
    my $raw_step   = $range / $num_labels;
    my $magnitude;
    if ($raw_step > 0) {
        $magnitude = 10 ** int(log($raw_step) / log(10));
    }
    else {
        $magnitude = 1;
    }
    my $nice_step = _round_to_nice($raw_step, $magnitude);
    $nice_step    = 0.01 if $nice_step <= 0;

    my $first = int($self->{y_min} / $nice_step) * $nice_step;
    $first += $nice_step if $first < $self->{y_min} - 1e-9;

    # Fondo de la franja de escala derecha
    $canvas->createRectangle(
        $x_left, 0, $self->{canvas_w}, $self->{canvas_h},
        -fill => '#ffffff', -outline => '', -tags => [$tag]
    );
    # Linea separadora panel / escala
    $canvas->createLine(
        $x_left, 0, $x_left, $self->{canvas_h},
        -fill => '#111827', -tags => [$tag]
    );

    my $val = $first;
    while ($val <= $self->{y_max} + $nice_step * 0.01) {
        my $y = $self->value_to_y($val);

        # Linea guia horizontal tenue
        $canvas->createLine(
            0, $y, $x_left, $y,
            -fill => '#111827', -dash => [2, 4], -tags => [$tag]
        );
        # Tick en la escala
        $canvas->createLine(
            $x_left, $y, $x_left + 5, $y,
            -fill => '#111827', -tags => [$tag]
        );
        # Etiqueta de precio/valor
        $canvas->createText(
            $x_left + 8, $y,
            -text   => sprintf($fmt, $val),
            -anchor => 'w',
            -fill   => '#111827',
            -font   => ['Courier', 9],
            -tags   => [$tag]
        );
        $val += $nice_step;
    }
}

# --- Helper estatico: redondea a un paso "bonito" para el eje Y ---
sub _round_to_nice {
    my ($raw, $mag) = @_;
    return $mag if $mag <= 0;
    my $norm = $raw / $mag;
    my $nice = $norm <= 1   ? 1
             : $norm <= 2   ? 2
             : $norm <= 2.5 ? 2.5
             : $norm <= 5   ? 5
             :                10;
    return $nice * $mag;
}

1;