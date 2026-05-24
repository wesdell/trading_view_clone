package Market::Panels::PricePanel;

# =============================================================================
# Market::Panels::PricePanel
# Panel principal: dibuja velas japonesas OHLC + escala Y de precios +
# eje temporal + crosshair + ultimo precio destacado.
#
# Reglas:
#   - El render no hace asunciones sobre el ChartEngine: recibe canvas,
#     datos y scale como parametros.
#   - El crosshair se inicializa UNA SOLA VEZ y luego se mueve con coords().
#   - Las funciones get_y_range / set_scale separan calculo de render.
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);

use constant {
    COLOR_BULL      => '#26a69a',   # verde alcista
    COLOR_BEAR      => '#ef5350',   # rojo bajista
    COLOR_BULL_BDR  => '#1a7a72',
    COLOR_BEAR_BDR  => '#c62828',
    COLOR_CROSS     => '#9598a1',
    COLOR_FG        => '#363a45',
    COLOR_GRID      => '#e0e3eb',
    COLOR_LAST_BG   => '#2962ff',   # azul TradingView para ultimo precio
    COLOR_INFO      => '#363a45',
    BG_COLOR        => '#ffffff',
    MIN_BODY_H      => 1,
};

# -----------------------------------------------------------------------------
# new
# -----------------------------------------------------------------------------
sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas        => $args{canvas},
        scale         => undef,
        price_scale_w => $args{price_scale_w} // 90,
        # Items del crosshair (creados una vez)
        _ch_hline     => undef,
        _ch_vline     => undef,
        _ch_label_bg  => undef,
        _ch_label     => undef,
        _ohlcv_label  => undef,
        _cross_ready  => 0,
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# _init_crosshair_objects
# Crea los items del crosshair UNA SOLA VEZ. Se llaman tras el primer
# render. En renders siguientes solo se ajustan sus coords (O(1)).
# -----------------------------------------------------------------------------
sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless $c;
    return if $self->{_cross_ready};

    $self->{_ch_vline} = $c->createLine(0, 0, 0, 1,
        -fill  => COLOR_CROSS,
        -dash  => [4, 4],
        -state => 'hidden',
        -tags  => ['crosshair_price'],
    );
    $self->{_ch_hline} = $c->createLine(0, 0, 1, 0,
        -fill  => COLOR_CROSS,
        -dash  => [4, 4],
        -state => 'hidden',
        -tags  => ['crosshair_price'],
    );
    $self->{_ch_label_bg} = $c->createRectangle(0, 0, 1, 1,
        -fill    => '#363a45',
        -outline => '#363a45',
        -state   => 'hidden',
        -tags    => ['crosshair_price'],
    );
    $self->{_ch_label} = $c->createText(0, 0,
        -text   => '',
        -fill   => '#ffffff',
        -anchor => 'center',
        -font   => 'TkFixedFont 8 bold',
        -state  => 'hidden',
        -tags   => ['crosshair_price'],
    );
    # Etiqueta OHLCV arriba izquierda
    $self->{_ohlcv_label} = $c->createText(8, 6,
        -text   => '',
        -fill   => COLOR_INFO,
        -anchor => 'nw',
        -font   => 'TkFixedFont 8',
        -state  => 'hidden',
        -tags   => ['ohlcv_label'],
    );

    $self->{_cross_ready} = 1;
}

# -----------------------------------------------------------------------------
# round
# Redondeo numerico auxiliar.
# -----------------------------------------------------------------------------
sub round {
    my ($self, $value, $decimals) = @_;
    $decimals //= 2;
    return sprintf("%.${decimals}f", $value) + 0;
}

# -----------------------------------------------------------------------------
# set_scale
# -----------------------------------------------------------------------------
sub set_scale {
    my ( $self, $scale ) = @_;
    $self->{scale} = $scale;
}

# -----------------------------------------------------------------------------
# get_y_range
# Min/Max de precios visibles + margen del 3% arriba y abajo.
# -----------------------------------------------------------------------------
sub get_y_range {
    my ($self, $data) = @_;
    return (0, 1) unless $data && @$data;

    my $max_p = $data->[0]{high};
    my $min_p = $data->[0]{low};
    for my $c (@$data) {
        $max_p = $c->{high} if $c->{high} > $max_p;
        $min_p = $c->{low}  if $c->{low}  < $min_p;
    }

    my $margin = ($max_p - $min_p) * 0.03;
    $margin = 1 if $margin < 1;

    return ($min_p - $margin, $max_p + $margin);
}

# -----------------------------------------------------------------------------
# render
# Dibuja fondo, escala Y (grilla + etiquetas), velas.
# Si una vela esta completamente fuera del rango Y visible, NO se dibuja
# (asi evitamos amontonarlas en el borde con zoom-in agresivo).
# -----------------------------------------------------------------------------
sub render {
    my ($self, $canvas, $data, $scale) = @_;
    return unless $data && @$data;

    $canvas->delete('candle');
    $canvas->delete('price_bg');

    # Fondo blanco del area de plot
    $canvas->createRectangle(0, 0,
        $scale->{canvas_w}, $scale->{canvas_h},
        -fill => BG_COLOR, -outline => BG_COLOR,
        -tags => ['price_bg'],
    );

    # Escala Y (grilla + etiquetas + borde)
    $scale->_draw_y_scale($canvas);

    # Geometria de la vela
    my $bar_w  = $scale->_plot_w / $scale->{visible_bars};
    my $body_w = $bar_w * 0.65;
    $body_w    = 1 if $body_w < 1;
    my $thin   = ($bar_w < 3) ? 1 : 0;

    # Limites Y del area de plot (para culling de velas fuera de rango)
    my $y_top_plot = $scale->_plot_y_top;
    my $y_bot_plot = $scale->_plot_y_bottom;

    for my $i (0 .. $#$data) {
        my $c   = $data->[$i];
        my $idx = $i + $scale->{offset};
        my $cx  = $scale->index_to_center_x($idx);

        # Culling: si la vela completa esta arriba o abajo del rango
        # visible, no la dibujamos. Las velas parcialmente visibles
        # SI se dibujan (clampeadas por value_to_y al borde del plot).
        next if ($c->{low}  > $scale->{max_val});
        next if ($c->{high} < $scale->{min_val});

        my $y_open  = $scale->value_to_y($c->{open});
        my $y_high  = $scale->value_to_y($c->{high});
        my $y_low   = $scale->value_to_y($c->{low});
        my $y_close = $scale->value_to_y($c->{close});

        my $bull   = ($c->{close} >= $c->{open});
        my $color  = $bull ? COLOR_BULL  : COLOR_BEAR;
        my $border = $thin ? $color : ($bull ? COLOR_BULL_BDR : COLOR_BEAR_BDR);

        # Cuerpo de la vela
        my $y_top  = ($y_close < $y_open) ? $y_close : $y_open;
        my $y_bot  = ($y_close > $y_open) ? $y_close : $y_open;
        my $body_h = $y_bot - $y_top;
        $body_h    = MIN_BODY_H if $body_h < MIN_BODY_H;

        $canvas->createRectangle(
            $cx - $body_w/2, $y_top,
            $cx + $body_w/2, $y_top + $body_h,
            -fill => $color, -outline => $border,
            -tags => ['candle'],
        );
        # Mecha superior
        $canvas->createLine($cx, $y_high, $cx, $y_top,
            -fill => $color, -tags => ['candle']);
        # Mecha inferior
        $canvas->createLine($cx, $y_top + $body_h, $cx, $y_low,
            -fill => $color, -tags => ['candle']);
    }
}

# -----------------------------------------------------------------------------
# render_last_visible_price
# Linea azul punteada + caja azul con el ultimo precio en la regleta Y.
# Solo se dibuja si el ultimo precio cae dentro del rango visible.
# -----------------------------------------------------------------------------
sub render_last_visible_price {
    my ($self, $canvas) = @_;
    return unless $self->{scale};

    my $scale = $self->{scale};
    $canvas->delete('last_price');

    my $last_close = $scale->{last_close};
    return unless defined $last_close;
    return unless $scale->value_in_range($last_close);

    my $y     = $scale->value_to_y($last_close);
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    # Linea horizontal punteada
    $canvas->createLine(0, $y, $x_sep, $y,
        -fill => COLOR_LAST_BG, -dash => [3,3], -width => 1,
        -tags => ['last_price']);

    # Caja con el precio en la regleta
    $canvas->createRectangle($x_sep+1, $y-9, $x_end-1, $y+9,
        -fill => COLOR_LAST_BG, -outline => COLOR_LAST_BG,
        -tags => ['last_price']);

    $canvas->createText($x_sep + ($x_end-$x_sep)/2, $y,
        -text => sprintf('%.2f', $last_close),
        -fill => '#ffffff', -anchor => 'center',
        -font => 'TkFixedFont 8 bold',
        -tags => ['last_price']);
}

# -----------------------------------------------------------------------------
# show_vline_only
# Muestra SOLO la linea vertical del crosshair (sin label horizontal ni caja
# de precio). Se usa cuando el cursor esta en OTRO panel pero queremos
# sincronizar la X aqui tambien.
# -----------------------------------------------------------------------------
sub show_vline_only {
    my ($self, $x) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale && defined $self->{_ch_vline};

    my $h     = $scale->{canvas_h};
    my $x_sep = $scale->_plot_w;

    if ($x < 0 || $x > $x_sep) {
        $c->itemconfigure('crosshair_price', -state => 'hidden');
        $c->itemconfigure('ohlcv_label',     -state => 'hidden');
        return;
    }

    # Snap al centro de la vela mas cercana
    my $idx    = $scale->x_to_index($x);
    my $snap_x = $scale->index_to_center_x($idx);

    $c->coords($self->{_ch_vline}, $snap_x, 0, $snap_x, $h);
    $c->itemconfigure($self->{_ch_vline},    -state => 'normal');
    $c->itemconfigure($self->{_ch_hline},    -state => 'hidden');
    $c->itemconfigure($self->{_ch_label_bg}, -state => 'hidden');
    $c->itemconfigure($self->{_ch_label},    -state => 'hidden');

    $c->raise('crosshair_price');
}

# -----------------------------------------------------------------------------
# show_ohlcv_info
# Actualiza la etiqueta OHLCV de la vela bajo el cursor. Se llama tanto
# cuando el mouse esta en este panel como cuando esta en el panel ATR (la X
# es la misma para los dos paneles).
# -----------------------------------------------------------------------------
sub show_ohlcv_info {
    my ($self, $candle_info) = @_;
    my $c = $self->{canvas};
    return unless $c && defined $self->{_ohlcv_label} && $candle_info;

    my $t = $candle_info->{time} // '';
    $t =~ s/T/ /;
    $t =~ s/:\d\d[-+]\d\d:\d\d$//;
    $t =~ s/\..*$//;
    my $txt = sprintf('%s   O %.2f  H %.2f  L %.2f  C %.2f  V %d',
        $t,
        $candle_info->{open}   // 0,
        $candle_info->{high}   // 0,
        $candle_info->{low}    // 0,
        $candle_info->{close}  // 0,
        $candle_info->{volume} // 0,
    );
    $c->itemconfigure($self->{_ohlcv_label},
        -text => $txt, -state => 'normal');
    $c->raise('ohlcv_label');
}

# -----------------------------------------------------------------------------
# hide_crosshair
# Oculta TODO el crosshair (incluido OHLCV label).
# -----------------------------------------------------------------------------
sub hide_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless $c;
    $c->itemconfigure('crosshair_price', -state => 'hidden');
    $c->itemconfigure('ohlcv_label',     -state => 'hidden');
}

# -----------------------------------------------------------------------------
# draw_crosshair
# Crosshair COMPLETO: vline + hline + caja con precio en regleta Y.
# Se usa cuando el cursor esta DENTRO de este panel.
# -----------------------------------------------------------------------------
sub draw_crosshair {
    my ($self, $x, $y, $candle_info) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale;
    return unless defined $self->{_ch_vline};

    my $h     = $scale->{canvas_h};
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    if ($x > $x_sep) {
        $c->itemconfigure('crosshair_price', -state => 'hidden');
        return;
    }

    # Snap al centro de la vela mas cercana (comportamiento TradingView)
    my $idx    = $scale->x_to_index($x);
    my $snap_x = $scale->index_to_center_x($idx);

    # Linea vertical: en el centro de la vela (snap)
    $c->coords($self->{_ch_vline}, $snap_x, 0, $snap_x, $h);
    $c->itemconfigure($self->{_ch_vline}, -state => 'normal');

    # Linea horizontal: libre en Y exacto del mouse
    $c->coords($self->{_ch_hline}, 0, $y, $x_sep, $y);
    $c->itemconfigure($self->{_ch_hline}, -state => 'normal');

    # Caja de precio en la regleta Y (usa Y del mouse, no snap)
    my $price = $scale->y_to_value($y);
    my $lbl_x = $x_sep + 1;
    my $lbl_w = $x_end - $x_sep - 2;
    $c->coords($self->{_ch_label_bg}, $lbl_x, $y-9, $lbl_x+$lbl_w, $y+9);
    $c->itemconfigure($self->{_ch_label_bg}, -state => 'normal');
    $c->coords($self->{_ch_label}, $lbl_x + $lbl_w/2, $y);
    $c->itemconfigure($self->{_ch_label},
        -text => sprintf('%.2f', $price), -state => 'normal');

    # Info OHLCV
    if ($candle_info) {
        $self->show_ohlcv_info($candle_info);
    }

    $c->raise('crosshair_price');
}

# -----------------------------------------------------------------------------
# draw_time_axis
# Eje temporal inferior con etiquetas tipo TradingView: "Wed 29", "03:00".
# -----------------------------------------------------------------------------
sub draw_time_axis {
    my ($self, $canvas, $timestamps) = @_;
    return unless $timestamps;
    my $scale = $self->{scale};
    return unless $scale;

    $canvas->delete('time_axis');

    my $y_sep  = $scale->{canvas_h} - $scale->{padding_bot};
    my $y_text = $y_sep + 4;

    # Linea separadora horizontal del eje
    $canvas->createLine(0, $y_sep, $scale->_plot_w, $y_sep,
        -fill => '#c9cdd7', -tags => ['time_axis']);

    # Fondo blanco bajo el eje
    $canvas->createRectangle(0, $y_sep, $scale->_plot_w, $scale->{canvas_h},
        -fill => BG_COLOR, -outline => BG_COLOR, -tags => ['time_axis']);

    for my $anchor (@$timestamps) {
        my $idx = $anchor->{index};
        next if $idx < $scale->{offset};
        next if $idx > $scale->{offset} + $scale->{visible_bars};

        my $x = $scale->index_to_center_x($idx);
        next if $x < 2 || $x > $scale->_plot_w - 2;

        # Marca corta
        $canvas->createLine($x, $y_sep, $x, $y_sep + 4,
            -fill => '#c9cdd7', -tags => ['time_axis']);

        # Etiqueta
        $canvas->createText($x, $y_text + 4,
            -text   => $anchor->{label},
            -fill   => '#787b86',
            -font   => 'TkFixedFont 7',
            -anchor => 'n',
            -tags   => ['time_axis']);
    }
}

1;