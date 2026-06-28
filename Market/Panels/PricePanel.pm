package Market::Panels::PricePanel;

use strict;
use warnings;
use POSIX qw(floor);

use constant {
    COLOR_BULL     => '#26a69a',
    COLOR_BEAR     => '#ef5350',
    COLOR_BULL_BDR => '#1a7a72',
    COLOR_BEAR_BDR => '#c62828',
    COLOR_CROSS    => '#9598a1',
    COLOR_FG       => '#363a45',
    COLOR_GRID     => '#e0e3eb',
    COLOR_LAST_BG  => '#69ea07',
    COLOR_INFO     => '#363a45',
    BG_COLOR       => '#ffffff',
    MIN_BODY_H     => 1,
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas        => $args{canvas},
        scale         => undef,
        price_scale_w => $args{price_scale_w} // 90,
        _ch_hline    => undef,
        _ch_vline    => undef,
        _ch_label_bg => undef,
        _ch_label    => undef,
        _ohlcv_label => undef,
        _time_label_bg => undef,
        _time_label    => undef,
        _cross_ready => 0,
    };
    bless $self, $class;
    return $self;
}

sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless $c;
    return if $self->{_cross_ready};

    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 1, -fill => COLOR_CROSS, -dash => [ 4, 4 ], -state => 'hidden', -tags => ['crosshair_price'],
    );
    $self->{_ch_hline} = $c->createLine(
        0, 0, 1, 0, -fill => COLOR_CROSS, -dash => [ 4, 4 ], -state => 'hidden', -tags => ['crosshair_price'],
    );
    $self->{_ch_label_bg} = $c->createRectangle(
        0, 0, 1, 1, -fill => '#363a45', -outline => '#363a45', -state => 'hidden', -tags => ['crosshair_price'],
    );
    $self->{_ch_label} = $c->createText(
        0, 0, -text => '', -fill => '#ffffff', -anchor => 'center', -font => 'TkFixedFont 8 bold', -state => 'hidden', -tags => ['crosshair_price'],
    );
    $self->{_ohlcv_label} = $c->createText(
        8, 6, -text => '', -fill => COLOR_INFO, -anchor => 'nw', -font => 'TkFixedFont 8', -state => 'hidden', -tags => ['ohlcv_label'],
    );
    $self->{_time_label_bg} = $c->createRectangle(
        0, 0, 1, 1, -fill => '#000000', -outline => '#000000', -state => 'hidden', -tags => ['time_label'],
    );
    $self->{_time_label} = $c->createText(
        0, 0, -text => '', -fill => '#ffffff', -anchor => 'center', -font => 'TkFixedFont 8', -state => 'hidden', -tags => ['time_label'],
    );

    $self->{_cross_ready} = 1;
}

sub round {
    my ( $self, $value, $decimals ) = @_;
    $decimals //= 2;
    return sprintf( "%.${decimals}f", $value ) + 0;
}

sub set_scale {
    my ( $self, $scale ) = @_;
    $self->{scale} = $scale;
}

sub get_y_range {
    my ( $self, $data ) = @_;
    return ( 0, 1 ) unless $data && @$data;

    my $max_p = $data->[0]{high};
    my $min_p = $data->[0]{low};
    for my $c (@$data) {
        $max_p = $c->{high} if $c->{high} > $max_p;
        $min_p = $c->{low}  if $c->{low} < $min_p;
    }

    my $margin = ( $max_p - $min_p ) * 0.03;
    $margin = 1 if $margin < 1;

    return ( $min_p - $margin, $max_p + $margin );
}

sub render {
    my ( $self, $canvas, $data, $scale ) = @_;
    return unless $data && @$data;

    $canvas->delete('candle');
    $canvas->delete('price_bg');

    $canvas->createRectangle(
        0,                  0,
        $scale->{canvas_w}, $scale->{canvas_h},
        -fill    => BG_COLOR,
        -outline => BG_COLOR,
        -tags    => ['price_bg'],
    );

    $scale->_draw_y_scale($canvas);

    my $bar_w  = $scale->_plot_w / $scale->{visible_bars};
    my $body_w = $bar_w * 0.65;
    $body_w = 1 if $body_w < 1;
    my $thin = ( $bar_w < 3 ) ? 1 : 0;

    # FIX: offset puede ser FRACCIONARIO (zoom anclado con Ctrl), pero el
    # array $data fue recortado en un indice ENTERO (slice_start). Usar
    # offset aqui desplazaria las velas en la magnitud del residuo
    # fraccionario. Si slice_start no viene (compatibilidad con llamadas
    # que no lo pasen), se cae al comportamiento original de Fase 1.
    my $start_idx = defined $scale->{slice_start}
        ? $scale->{slice_start}
        : ( $scale->{offset} < 0 ? 0 : $scale->{offset} );

    for my $i ( 0 .. $#$data ) {
        my $c   = $data->[$i];
        my $idx = $i + $start_idx;
        my $cx  = $scale->index_to_center_x($idx);

        next if ( $c->{low} > $scale->{max_val} );
        next if ( $c->{high} < $scale->{min_val} );

        my $y_open  = $scale->value_to_y( $c->{open} );
        my $y_high  = $scale->value_to_y( $c->{high} );
        my $y_low   = $scale->value_to_y( $c->{low} );
        my $y_close = $scale->value_to_y( $c->{close} );

        my $bull  = ( $c->{close} >= $c->{open} );
        my $color = $bull ? COLOR_BULL : COLOR_BEAR;
        my $border = $thin ? $color : ( $bull ? COLOR_BULL_BDR : COLOR_BEAR_BDR );

        my $y_top  = ( $y_close < $y_open ) ? $y_close : $y_open;
        my $y_bot  = ( $y_close > $y_open ) ? $y_close : $y_open;
        my $body_h = $y_bot - $y_top;
        $body_h = MIN_BODY_H if $body_h < MIN_BODY_H;

        $canvas->createRectangle(
            $cx - $body_w / 2, $y_top,
            $cx + $body_w / 2, $y_top + $body_h,
            -fill    => $color,
            -outline => $border,
            -tags    => ['candle'],
        );

        $canvas->createLine(
            $cx, $y_high, $cx, $y_top,
            -fill => $color,
            -tags => ['candle']
        );

        $canvas->createLine(
            $cx, $y_top + $body_h, $cx, $y_low,
            -fill => $color,
            -tags => ['candle']
        );
    }
}

sub render_last_visible_price {
    my ( $self, $canvas ) = @_;
    return unless $self->{scale};

    my $scale = $self->{scale};
    $canvas->delete('last_price');

    my $last_close = $scale->{last_close};
    return unless defined $last_close;
    return unless $scale->value_in_range($last_close);

    my $y     = $scale->value_to_y($last_close);
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    $canvas->createLine(
        0, $y, $x_sep, $y,
        -fill  => COLOR_LAST_BG,
        -dash  => [ 3, 3 ],
        -width => 1,
        -tags  => ['last_price']
    );

    $canvas->createRectangle(
        $x_sep + 1, $y - 9, $x_end - 1, $y + 9,
        -fill    => COLOR_LAST_BG,
        -outline => COLOR_LAST_BG,
        -tags    => ['last_price']
    );

    $canvas->createText(
        $x_sep + ( $x_end - $x_sep ) / 2, $y,
        -text   => sprintf( '%.2f', $last_close ),
        -fill   => '#ffffff',
        -anchor => 'center',
        -font   => 'TkFixedFont 8 bold',
        -tags   => ['last_price']
    );
}

sub show_vline_only {
    my ( $self, $x ) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale && defined $self->{_ch_vline};

    my $h     = $scale->{canvas_h};
    my $x_sep = $scale->_plot_w;

    if ( $x < 0 || $x > $x_sep ) {
        $c->itemconfigure( 'crosshair_price', -state => 'hidden' );
        $c->itemconfigure( 'ohlcv_label',     -state => 'hidden' );
        return;
    }

    my $idx    = $scale->x_to_index($x);
    my $snap_x = $scale->index_to_center_x($idx);

    $c->coords( $self->{_ch_vline}, $snap_x, 0, $snap_x, $h );
    $c->itemconfigure( $self->{_ch_vline},    -state => 'normal' );
    $c->itemconfigure( $self->{_ch_hline},    -state => 'hidden' );
    $c->itemconfigure( $self->{_ch_label_bg}, -state => 'hidden' );
    $c->itemconfigure( $self->{_ch_label},    -state => 'hidden' );

    $c->raise('crosshair_price');
}

sub show_ohlcv_info {
    my ( $self, $candle_info ) = @_;
    my $c = $self->{canvas};
    return unless $c && defined $self->{_ohlcv_label} && $candle_info;

    my $t = $candle_info->{time} // '';
    $t =~ s/T/ /;
    $t =~ s/:\d\d[-+]\d\d:\d\d$//;
    $t =~ s/\..*$//;
    my $txt = sprintf(
        '%s   O %.2f  H %.2f  L %.2f  C %.2f  V %d',
        $t,
        $candle_info->{open}   // 0,
        $candle_info->{high}   // 0,
        $candle_info->{low}    // 0,
        $candle_info->{close}  // 0,
        $candle_info->{volume} // 0,
    );
    $c->itemconfigure(
        $self->{_ohlcv_label},
        -text  => $txt,
        -state => 'normal'
    );
    $c->raise('ohlcv_label');
}

sub draw_time_label {
    my ( $self, $snap_x, $candle_info ) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale;
    return unless $candle_info;

    my $time = $candle_info->{time} // '';

    my %months = (
        '01' => 'Jan', '02' => 'Feb', '03' => 'Mar', '04' => 'Apr',
        '05' => 'May', '06' => 'Jun', '07' => 'Jul', '08' => 'Aug',
        '09' => 'Sep', '10' => 'Oct', '11' => 'Nov', '12' => 'Dec',
    );
    my @days = qw(Sun Mon Tue Wed Thu Fri Sat);

    if ( $time =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/ ) {
        my ( $year, $month, $day, $hour, $min ) = ( $1, $2, $3, $4+0, $5+0 );

        my $ts   = $candle_info->{ts} // 0;
        my $wday = ( gmtime( $ts + 5*3600 ) )[6];

        my $dow = $days[$wday];
        my $mon = $months{$month} // $month;
        my $yy  = substr( $year, 2, 2 );

        $time = sprintf( '%s %d %s %s %d:%02d',
            $dow, $day+0, $mon, $yy, $hour, $min );
    }

    my $y     = $scale->{canvas_h} - 10;
    my $pad_x = 6;
    my $pad_y = 3;

    $c->coords( $self->{_time_label}, $snap_x, $y );
    $c->itemconfigure( $self->{_time_label}, -text => $time, -state => 'normal' );

    my @bbox = $c->bbox( $self->{_time_label} );
    return unless @bbox;

    my ( $x1, $y1, $x2, $y2 ) = @bbox;
    $c->coords( $self->{_time_label_bg},
        $x1 - $pad_x, $y1 - $pad_y,
        $x2 + $pad_x, $y2 + $pad_y );
    $c->itemconfigure( $self->{_time_label_bg}, -state => 'normal' );
    $c->raise('time_label');
}

sub hide_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless $c;
    $c->itemconfigure( 'crosshair_price', -state => 'hidden' );
    $c->itemconfigure( 'ohlcv_label',     -state => 'hidden' );
    $c->itemconfigure( 'time_label',      -state => 'hidden' );
}

# -----------------------------------------------------------------------------
# draw_crosshair
# FIX: Etiqueta de precio ajustada y forzada matemáticamente a múltiplos
# de 0.25 (Tick Size de mercado). La línea horizontal también se sincroniza.
# -----------------------------------------------------------------------------
sub draw_crosshair {
    my ( $self, $x, $y, $candle_info ) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless $c && $scale;
    return unless defined $self->{_ch_vline};

    my $h     = $scale->{canvas_h};
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    if ( $x > $x_sep ) {
        $c->itemconfigure( 'crosshair_price', -state => 'hidden' );
        return;
    }

    # Snap de la línea vertical a la vela
    my $idx    = $scale->x_to_index($x);
    my $snap_x = $scale->index_to_center_x($idx);

    $c->coords( $self->{_ch_vline}, $snap_x, 0, $snap_x, $h );
    $c->itemconfigure( $self->{_ch_vline}, -state => 'normal' );

    # SNAP MATEMÁTICO: Redondeo del precio al múltiplo de 0.25 más cercano
    my $raw_price     = $scale->y_to_value($y);
    my $snapped_price = floor( $raw_price * 4 + 0.5 ) / 4;
    
    # Recalcular la coordenada Y exacta basándose en el precio redondeado
    my $snap_y = $scale->value_to_y($snapped_price);

    # Línea horizontal forzada a moverse de a saltos ("ticks")
    $c->coords( $self->{_ch_hline}, 0, $snap_y, $x_sep, $snap_y );
    $c->itemconfigure( $self->{_ch_hline}, -state => 'normal' );

    # Dibujar la etiqueta y su fondo sobre la coordenada anclada
    my $lbl_x = $x_sep + 1;
    my $lbl_w = $x_end - $x_sep - 2;
    $c->coords( $self->{_ch_label_bg}, $lbl_x, $snap_y - 9, $lbl_x + $lbl_w, $snap_y + 9 );
    $c->itemconfigure( $self->{_ch_label_bg}, -state => 'normal' );
    $c->coords( $self->{_ch_label}, $lbl_x + $lbl_w / 2, $snap_y );
    $c->itemconfigure(
        $self->{_ch_label},
        -text  => sprintf( '%.2f', $snapped_price ),
        -state => 'normal'
    );

    if ($candle_info) {
        $self->show_ohlcv_info($candle_info);
        $self->draw_time_label( $snap_x, $candle_info );
    }

    $c->raise('crosshair_price');
}

sub draw_time_axis {
    my ( $self, $canvas, $timestamps ) = @_;
    return unless $timestamps;
    my $scale = $self->{scale};
    return unless $scale;

    $canvas->delete('time_axis');

    my $y_sep  = $scale->{canvas_h} - $scale->{padding_bot};
    my $y_text = $y_sep + 4;

    $canvas->createLine(
        0, $y_sep, $scale->_plot_w, $y_sep,
        -fill => '#c9cdd7',
        -tags => ['time_axis']
    );

    $canvas->createRectangle(
        0, $y_sep, $scale->_plot_w, $scale->{canvas_h},
        -fill    => BG_COLOR,
        -outline => BG_COLOR,
        -tags    => ['time_axis']
    );

    for my $anchor (@$timestamps) {
        my $idx = $anchor->{index};
        next if $idx < $scale->{offset};
        next if $idx > $scale->{offset} + $scale->{visible_bars};

        my $x = $scale->index_to_center_x($idx);
        next if $x < 2 || $x > $scale->_plot_w - 2;

        $canvas->createLine(
            $x, $y_sep, $x, $y_sep + 4,
            -fill => '#c9cdd7',
            -tags => ['time_axis']
        );

        my $font = $anchor->{is_day} ? 'TkFixedFont 7 bold' : 'TkFixedFont 7';
        $canvas->createText(
            $x, $y_text + 4,
            -text   => $anchor->{label},
            -fill   => '#787b86',
            -font   => $font,
            -anchor => 'n',
            -tags   => ['time_axis']
        );
    }
}

1;