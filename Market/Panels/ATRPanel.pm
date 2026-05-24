package Market::Panels::ATRPanel;

# =============================================================================
# Market::Panels::ATRPanel
# Panel inferior: linea continua del indicador ATR + regleta Y propia.
#
# Coordenadas:
#   visible_atr es un slice RELATIVO (i=0 = primera barra visible).
#   scale se construye con offset=0 y visible_bars = len(visible_atr).
#   Asi x = index_to_center_x(i) coincide con el panel de precios.
#
# Color: linea rojo bordo #b71c1c, grosor 1.5px.
# =============================================================================

use strict;
use warnings;

# ------------------------------------------------------------------------------
# Paleta clara estilo TradingView Light
# ------------------------------------------------------------------------------

use constant {
    COLOR_ATR   => '#b71c1c',
    COLOR_CROSS => '#9598a1',
    BG_COLOR    => '#ffffff',
};

# ------------------------------------------------------------------------------
# new
# Inicializa el panel ATR.
# ------------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;

    my $self = {
        canvas        => $args{canvas},
        scale         => undef,
        price_scale_w => $args{price_scale_w} // 90,
        _ch_vline     => undef,
        _ch_hline     => undef,
        _ch_label_bg  => undef,
        _ch_label     => undef,
        _cross_ready  => 0,
    };

    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# _init_crosshair
# Crea los items del crosshair UNA SOLA VEZ.
# -----------------------------------------------------------------------------
sub _init_crosshair {
    my ($self) = @_;

    my $c = $self->{canvas};
    return unless $c;
    return if $self->{_cross_ready};

    $self->{_ch_vline} = $c->createLine(0, 0, 0, 1,
        -fill  => COLOR_CROSS,
        -dash  => [4, 4],
        -state => 'hidden',
        -tags  => ['crosshair_atr']);
    $self->{_ch_hline} = $c->createLine(0, 0, 1, 0,
        -fill  => COLOR_CROSS,
        -dash  => [4, 4],
        -state => 'hidden',
        -tags  => ['crosshair_atr']);
    $self->{_ch_label_bg} = $c->createRectangle(0, 0, 1, 1,
        -fill    => '#363a45',
        -outline => '#363a45',
        -state   => 'hidden',
        -tags    => ['crosshair_atr']);
    $self->{_ch_label} = $c->createText(0, 0,
        -text   => '',
        -fill   => '#ffffff',
        -anchor => 'center',
        -font   => 'TkFixedFont 8 bold',
        -state  => 'hidden',
        -tags   => ['crosshair_atr']);

    $self->{_cross_ready} = 1;
}

# -----------------------------------------------------------------------------
# get_y_range
# Min/Max del ATR visible. ATR siempre >= 0.
# Margen del 10% sobre el max para que la linea no toque el borde superior.
# El piso es 0 (mejor visualizacion de la base).
# -----------------------------------------------------------------------------
sub get_y_range {
    my ($self, $values) = @_;
    return (0, 1) unless $values && @$values;

    my $max;
    for my $v (@$values) {
        next unless defined $v;
        $max = $v if !defined $max || $v > $max;
    }
    return (0, 1) unless defined $max;

    my $mg = $max * 0.10;
    $mg = 0.0001 if $mg < 0.0001;

    return (0, $max + $mg);
}

# -----------------------------------------------------------------------------
# set_scale
# -----------------------------------------------------------------------------
sub set_scale {
    my ($self, $scale) = @_;

    $self->{scale} = $scale;
}

# -----------------------------------------------------------------------------
# render
# Dibuja fondo + escala + linea ATR. Maneja gaps (undef) y valores fuera
# del rango Y (se interrumpe el segmento al salir del rango).
#
# $values: arrayref relativo (i=0 = primera barra visible).
# $scale : con offset=0, visible_bars = scalar(@$values).
# -----------------------------------------------------------------------------
sub render {
    my ($self, $canvas, $values, $scale) = @_;
    return unless $values && @$values;

    $canvas->delete('atr_all');

    # Fondo blanco
    $canvas->createRectangle(0, 0, $scale->{canvas_w}, $scale->{canvas_h},
        -fill => BG_COLOR, -outline => BG_COLOR, -tags => ['atr_all']);

    # Escala Y (grilla + etiquetas)
    $scale->_draw_y_scale($canvas);

    # Etiqueta del nombre del indicador (arriba izquierda)
    $canvas->createText(8, 4,
        -text   => 'ATR(14)',
        -fill   => COLOR_ATR,
        -anchor => 'nw',
        -font   => 'TkFixedFont 8 bold',
        -tags   => ['atr_all'],
    );

    # Construir segmentos: cada gap (undef) o valor fuera de rango
    # interrumpe la linea (estilo TradingView).
    my @seg;
    my $n = scalar @$values;

    for my $i (0 .. $n - 1) {
        my $v = $values->[$i];
        if (defined $v && $scale->value_in_range($v)) {
            my $x = $scale->index_to_center_x($i);
            my $y = $scale->value_to_y($v);
            push @seg, $x, $y;
        } else {
            if (@seg >= 4) {
                $canvas->createLine(@seg,
                    -fill  => COLOR_ATR,
                    -width => 1.5,
                    -tags  => ['atr_all'],
                );
            }
            @seg = ();
        }
    }
    if (@seg >= 4) {
        $canvas->createLine(@seg,
            -fill  => COLOR_ATR,
            -width => 1.5,
            -tags  => ['atr_all'],
        );
    }
}

# -----------------------------------------------------------------------------
# render_last_visible_value
# Linea horizontal + caja con el ultimo valor visible del ATR.
# Solo se dibuja si esta dentro del rango visible.
# -----------------------------------------------------------------------------
sub render_last_visible_value {
    my ($self, $canvas) = @_;
    return unless $self->{scale};
    my $scale    = $self->{scale};
    my $last_val = $scale->{last_atr_val};
    return unless defined $last_val;
    return unless $scale->value_in_range($last_val);

    my $y     = $scale->value_to_y($last_val);
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    $canvas->createLine(0, $y, $x_sep, $y,
        -fill => COLOR_ATR, -dash => [3,3], -width => 1, -tags => ['atr_all']);
    $canvas->createRectangle($x_sep+1, $y-9, $x_end-1, $y+9,
        -fill => COLOR_ATR, -outline => COLOR_ATR, -tags => ['atr_all']);
    $canvas->createText($x_sep + ($x_end-$x_sep)/2, $y,
        -text   => sprintf('%.4f', $last_val),
        -fill   => '#ffffff',
        -anchor => 'center',
        -font   => 'TkFixedFont 8 bold',
        -tags   => ['atr_all']);
}

# -----------------------------------------------------------------------------
# show_vline_only
# Muestra SOLO la linea vertical del crosshair (sincronizacion con el
# panel de precios cuando el cursor esta arriba).
# -----------------------------------------------------------------------------
sub show_vline_only {
    my ($self, $x) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale && defined $self->{_ch_vline};

    my $h     = $scale->{canvas_h};
    my $x_sep = $scale->_plot_w;

    if ($x < 0 || $x > $x_sep) {
        $c->itemconfigure('crosshair_atr', -state => 'hidden');
        return;
    }

    $c->coords($self->{_ch_vline}, $x, 0, $x, $h);
    $c->itemconfigure($self->{_ch_vline},    -state => 'normal');
    $c->itemconfigure($self->{_ch_hline},    -state => 'hidden');
    $c->itemconfigure($self->{_ch_label_bg}, -state => 'hidden');
    $c->itemconfigure($self->{_ch_label},    -state => 'hidden');

    $c->raise('crosshair_atr');
}

# -----------------------------------------------------------------------------
# hide_crosshair
# Oculta TODO el crosshair de este panel.
# -----------------------------------------------------------------------------
sub hide_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless $c;
    $c->itemconfigure('crosshair_atr', -state => 'hidden');
}

# -----------------------------------------------------------------------------
# draw_crosshair
# Mueve los items del crosshair a la posicion (x, y) usando coords().
# -----------------------------------------------------------------------------
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale && defined $self->{_ch_vline};

    my $h     = $scale->{canvas_h};
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    if ($x > $x_sep) {
        $c->itemconfigure('crosshair_atr', -state => 'hidden');
        return;
    }

    $c->coords($self->{_ch_vline}, $x, 0, $x, $h);
    $c->itemconfigure($self->{_ch_vline}, -state => 'normal');

    $c->coords($self->{_ch_hline}, 0, $y, $x_sep, $y);
    $c->itemconfigure($self->{_ch_hline}, -state => 'normal');

    my $val = $scale->y_to_value($y);
    my $lx  = $x_sep + 1;
    my $lw  = $x_end - $x_sep - 2;
    $c->coords($self->{_ch_label_bg}, $lx, $y-9, $lx+$lw, $y+9);
    $c->itemconfigure($self->{_ch_label_bg}, -state => 'normal');
    $c->coords($self->{_ch_label}, $lx + $lw/2, $y);
    $c->itemconfigure($self->{_ch_label},
        -text => sprintf('%.4f', $val), -state => 'normal');

    $c->raise('crosshair_atr');
}

1;