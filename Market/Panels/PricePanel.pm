package Market::Panels::PricePanel;

# ==============================================================================
# Market::Panels::PricePanel
# Responsabilidad: Renderizar el grafico principal de precios (velas japonesas).
# Maneja escalado vertical, dibujo de velas OHLC, crosshair y eje de tiempo.
# ==============================================================================

use strict;
use warnings;
use POSIX qw(floor);

# Paleta de colores estilo TradingView
my $COLOR_BG        = '#ffffff';

# Velas
my $COLOR_BULL      = '#089981';
my $COLOR_BEAR      = '#f23645';

# Crosshair
my $COLOR_CROSSH    = '#b2b5be';

# Textos
my $COLOR_PRICE_TXT = '#131722';
my $COLOR_TIME_TXT  = '#6b7280';

# ------------------------------------------------------------------------------
# new
# Inicializa el panel de precios.
# Parametros (hash):
#   canvas   : widget Tk::Canvas donde se dibuja
#   canvas_w : ancho del canvas en pixels
#   canvas_h : alto del canvas en pixels
#   scale_w  : ancho reservado para la escala derecha (px)
# ------------------------------------------------------------------------------
sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas   => $args{canvas},
        canvas_w => $args{canvas_w} // 1200,
        canvas_h => $args{canvas_h} // 400,
        scale_w  => $args{scale_w}  // 70,
        scale    => undef,

        # Estado del crosshair (objetos pre-creados)
        _ch_vline => undef,
        _ch_hline => undef,
        _ch_label => undef,
        _ch_box   => undef,

        # Ultimo precio visible para la etiqueta derecha
        _last_price => undef,
    };
    bless $self, $class;
    $self->_init_crosshair_objects();
    return $self;
}

# ------------------------------------------------------------------------------
# _init_crosshair_objects
# Pre-crea los elementos graficos del crosshair en el canvas.
# Se crean fuera de pantalla y se reposicionan en cada movimiento del mouse.
# Esto evita crear/destruir objetos Tk en cada frame — optimizacion clave.
# ------------------------------------------------------------------------------
sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless defined $c;

    $self->{_ch_vline} = $c->createLine(
        -1, 0, -1, $self->{canvas_h},
        -fill => $COLOR_CROSSH,
        -dash => [ 1, 1 ],
        -tags => ['crosshair']
    );
    $self->{_ch_hline} = $c->createLine(
        0, -1, $self->{canvas_w}, -1,
        -fill => $COLOR_CROSSH,
        -dash => [ 1, 1 ],
        -tags => ['crosshair']
    );
    $self->{_ch_box} = $c->createRectangle(
        $self->_scale_x(), -1, $self->{canvas_w}, -1,
        -fill    => $COLOR_CROSSH,
        -outline => '',
        -tags    => ['crosshair']
    );
    $self->{_ch_label} = $c->createText(
        $self->_scale_x() + 4, -1,
        -text   => '',
        -anchor => 'w',
        -fill   => $COLOR_PRICE_TXT,
        -font   => [ 'Courier', 9, 'bold' ],
        -tags   => ['crosshair']
    );
}

# ------------------------------------------------------------------------------
# round
# Redondeo auxiliar al entero mas cercano.
# ------------------------------------------------------------------------------
sub round {
    my ( $self, $value ) = @_;
    return int( $value + 0.5 );
}

# ------------------------------------------------------------------------------
# get_y_range
# Calcula el rango de precios min/max del slice visible con margen del 5%.
# Base para el escalado vertical automatico.
# Parametro $data: arrayref de hashrefs de velas
# Retorna: ($y_min, $y_max)
# ------------------------------------------------------------------------------
sub get_y_range {
    my ( $self, $data ) = @_;

    return ( 0, 1 ) unless @$data;

    my $min = $data->[0]{low};
    my $max = $data->[0]{high};

    foreach my $c (@$data) {

        $min = $c->{low}
          if $c->{low} < $min;

        $max = $c->{high}
          if $c->{high} > $max;
    }

    # -----------------------------------
    # Padding dinámico
    # -----------------------------------

    my $range = $max - $min;

    $range = 1
      if $range <= 0;

    my $padding = $range * 0.12;

    # Padding mínimo estable
    $padding = 0.5
      if $padding < 0.5;

    my $target_min = $min - $padding;

    my $target_max = $max + $padding;

    # -----------------------------------
    # Suavizado temporal
    # -----------------------------------

    if (   defined $self->{_smooth_y_min}
        && defined $self->{_smooth_y_max} )
    {

        my $alpha = 0.18;

        $self->{_smooth_y_min} =
          $self->{_smooth_y_min} +
          ( ( $target_min - $self->{_smooth_y_min} ) * $alpha );

        $self->{_smooth_y_max} =
          $self->{_smooth_y_max} +
          ( ( $target_max - $self->{_smooth_y_max} ) * $alpha );
    }
    else {

        $self->{_smooth_y_min} = $target_min;

        $self->{_smooth_y_max} = $target_max;
    }

    return ( $self->{_smooth_y_min}, $self->{_smooth_y_max}, );
}

# ------------------------------------------------------------------------------
# set_scale
# Asigna el objeto Scales activo a este panel.
# Parametro $scale: objeto Market::Panels::Scales
# ------------------------------------------------------------------------------
sub set_scale {
    my ( $self, $scale ) = @_;
    $self->{scale} = $scale;
}

# ------------------------------------------------------------------------------
# render
# Dibuja todas las velas visibles. Funcion principal del panel.
# Parametros:
#   $canvas : widget Tk::Canvas
#   $data   : arrayref de velas visibles (slice de MarketData)
#   $scale  : objeto Market::Panels::Scales configurado para esta vista
# ------------------------------------------------------------------------------
sub render {
    my ( $self, $canvas, $data, $scale ) = @_;

    # Sincronizar escala interna con la recibida
    $self->set_scale($scale);

    $canvas->delete('candles');
    $canvas->delete('yscale');
    $canvas->delete('timescale');
    $canvas->delete('lastprice');

    # Fondo oscuro
    # Crear fondo una sola vez
    unless ( $self->{_bg_created} ) {

        $canvas->createRectangle(
            0,
            0,
            $self->{canvas_w},
            $self->{canvas_h},

            -fill    => $COLOR_BG,
            -outline => '',
            -tags    => ['background']
        );

        $self->{_bg_created} = 1;
    }

    # FIX: usar _bar_width (metodo privado de Scales)
    my $bar_w = $scale->_bar_width();

    # Limitar tamaños extremos
    $bar_w = 2  if $bar_w < 2;
    $bar_w = 80 if $bar_w > 80;

    # Separación visual consistente
    my $body_w = $bar_w * 0.72;

    # Mantener visible el cuerpo
    $body_w = 1 if $body_w < 1;

    # Evitar cuerpos absurdamente grandes
    $body_w = $bar_w - 2
      if $body_w > ( $bar_w - 2 );

    for my $i ( 0 .. $#$data ) {
        my $c = $data->[$i];

        my $idx = $scale->{offset} + $i;
        my $cx  = $scale->index_to_center_x($idx);

        # Saltar velas completamente fuera del viewport
        next if $cx < -$bar_w;
        next if $cx > $scale->_chart_w() + $bar_w;

        my $y_open  = $scale->value_to_y( $c->{open} );
        my $y_close = $scale->value_to_y( $c->{close} );
        my $y_high  = $scale->value_to_y( $c->{high} );
        my $y_low   = $scale->value_to_y( $c->{low} );

        my $bull  = $c->{close} >= $c->{open};
        my $color = $bull ? $COLOR_BULL : $COLOR_BEAR;

        # Mecha (high - low)
        $canvas->createLine(
            $cx, $y_high, $cx, $y_low,
            -fill  => $color,
            -width => 1,
            -tags  => ['candles']
        );

        # Cuerpo (open - close)
        my $y_top = $bull ? $y_close : $y_open;
        my $y_bot = $bull ? $y_open  : $y_close;
        my $half  = $body_w / 2.0;
        $y_bot = $y_top + 1 if ( $y_bot - $y_top ) < 1;

        $canvas->createRectangle(
            $cx - $half, $y_top, $cx + $half, $y_bot,
            -fill    => $color,
            -outline => $color,
            -tags    => ['candles']
        );
    }

  # FIX: guardar ultimo precio visible antes de llamar render_last_visible_price
    $self->{_last_price} = $data->[-1]{close} if @$data;

    # Escala derecha Y y etiqueta del ultimo precio
    $scale->_draw_y_scale( $canvas, '%.2f', 'yscale' );
    $self->render_last_visible_price($canvas);
}

# ------------------------------------------------------------------------------
# render_last_visible_price
# Dibuja la etiqueta del ultimo precio visible en la escala derecha.
# ------------------------------------------------------------------------------
sub render_last_visible_price {
    my ( $self, $canvas ) = @_;
    my $scale = $self->{scale};
    return unless defined $scale && defined $self->{_last_price};

    $canvas->delete('lastprice');

    my $price = $self->{_last_price};
    my $y     = $scale->value_to_y($price);
    my $x     = $scale->_chart_w();
    my $label = sprintf( '%.2f', $price );
    my $lw    = length($label) * 7 + 8;

    $canvas->createRectangle(
        $x, $y - 9, $x + $lw, $y + 9,
        -fill    => $COLOR_CROSSH,
        -outline => '',
        -tags    => ['lastprice']
    );
    $canvas->createText(
        $x + 4, $y,
        -text   => $label,
        -anchor => 'w',
        -fill   => $COLOR_PRICE_TXT,
        -font   => [ 'Courier', 9, 'bold' ],
        -tags   => ['lastprice']
    );
}

# ------------------------------------------------------------------------------
# draw_crosshair
# Mueve los objetos pre-creados del crosshair a la posicion del mouse.
# Parametros: $x, $y coordenadas en pixels dentro del canvas
# ------------------------------------------------------------------------------
sub draw_crosshair {
    my ( $self, $x, $y ) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless defined $c && defined $scale;

    my $w = $self->{canvas_w};
    my $h = $self->{canvas_h};

    $c->coords( $self->{_ch_vline}, $x, 0,  $x, $h );
    $c->coords( $self->{_ch_hline}, 0,  $y, $w, $y );

    my $price = $scale->y_to_value($y);
    my $label = sprintf( '%.2f', $price );
    my $lw    = length($label) * 7 + 8;
    my $sx    = $self->_scale_x();

    $c->coords( $self->{_ch_box}, $sx, $y - 9, $w, $y + 9 );
    $c->coords( $self->{_ch_label}, $sx + 4, $y );
    $c->itemconfigure( $self->{_ch_label}, -text => $label );

    $c->raise('crosshair');
}

# ------------------------------------------------------------------------------
# draw_time_axis
# Dibuja el eje temporal en la parte inferior del panel de precios.
# Parametros:
#   $canvas     : widget Tk::Canvas
#   $timestamps : arrayref de hashrefs { idx => ..., label => ... }
# ------------------------------------------------------------------------------
sub draw_time_axis {
    my ( $self, $canvas, $timestamps ) = @_;
    my $scale = $self->{scale};
    return unless defined $scale;

    $canvas->delete('timescale');

    my $y_tick  = $self->{canvas_h} - $scale->{padding_bot};
    my $y_label = $self->{canvas_h} - 8;

    for my $entry (@$timestamps) {
        my $idx   = $entry->{idx};
        my $label = $entry->{label};
        my $x     = $scale->index_to_center_x($idx);

        next if $x < 0 || $x > $scale->_chart_w();

        # Tick vertical corto
        $canvas->createLine(
            $x, $y_tick, $x, $y_tick + 4,
            -fill => '#787b86',
            -tags => ['timescale']
        );

        # Etiqueta de tiempo
        $canvas->createText(
            $x, $y_label,
            -text   => $label,
            -anchor => 'center',
            -fill   => $COLOR_TIME_TXT,
            -font   => [ 'Courier', 8 ],
            -tags   => ['timescale']
        );
    }
}

# ==============================================================================
# HELPERS PRIVADOS
# ==============================================================================

# Coordenada X donde comienza la franja de escala derecha
sub _scale_x {
    my ($self) = @_;
    return $self->{canvas_w} - $self->{scale_w};
}

1;
