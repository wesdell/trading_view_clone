package Market::Panels::Scales;

use strict;
use warnings;
use POSIX qw(floor);

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        canvas_w      => $args{canvas_w}      // 800,
        canvas_h      => $args{canvas_h}      // 400,
        price_scale_w => $args{price_scale_w} // 90,
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

sub _plot_w {
    my ($self) = @_;
    return $self->{canvas_w} - $self->{price_scale_w};
}

sub _plot_h {
    my ($self) = @_;
    return $self->{canvas_h} - $self->{padding_top} - $self->{padding_bot};
}

sub _plot_y_bottom {
    my ($self) = @_;
    return $self->{padding_top} + $self->_plot_h;
}

sub _plot_y_top {
    my ($self) = @_;
    return $self->{padding_top};
}

sub index_to_x {
    my ( $self, $index ) = @_;
    my $bar_w = $self->_plot_w / $self->{visible_bars};
    return ( $index - $self->{offset} ) * $bar_w;
}

sub x_to_index {
    my ( $self, $x ) = @_;
    my $bar_w = $self->_plot_w / $self->{visible_bars};
    my $idx = int( ( $x / $bar_w ) + $self->{offset} );
    return $idx;
}

sub x_to_index_float {
    my ( $self, $x ) = @_;
    my $bar_w = $self->_plot_w / $self->{visible_bars};
    return ( $x / $bar_w ) + $self->{offset};
}

sub index_to_center_x {
    my ( $self, $idx ) = @_;
    my $bar_w = $self->_plot_w / $self->{visible_bars};
    return ( ( $idx - $self->{offset} ) * $bar_w ) + ( $bar_w / 2 );
}

sub value_to_y {
    my ( $self, $value ) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    return $self->{padding_top} if $range == 0;

    my $n = ( $value - $self->{min_val} ) / $range;
    $n = 0 if $n < 0;
    $n = 1 if $n > 1;

    return $self->{padding_top} + $self->_plot_h * ( 1 - $n );
}

sub value_to_y_raw {
    my ( $self, $value ) = @_;
    my $range = $self->{max_val} - $self->{min_val};
    return $self->{padding_top} if $range == 0;
    
    my $n = ( $value - $self->{min_val} ) / $range;
    my $y = $self->{padding_top} + $self->_plot_h * ( 1 - $n );
    
    # Límite seguro para la memoria gráfica (Evita desbordamientos de 16-bits)
    $y = -10000 if $y < -10000;
    $y = 10000  if $y > 10000;
    
    return $y;
}

sub value_in_range {
    my ( $self, $value ) = @_;
    return ( $value >= $self->{min_val} && $value <= $self->{max_val} ) ? 1 : 0;
}

sub y_to_value {
    my ( $self, $y ) = @_;
    my $plot_h = $self->_plot_h;
    return $self->{min_val} if $plot_h == 0;
    my $n = 1 - ( $y - $self->{padding_top} ) / $plot_h;
    $n = 0 if $n < 0;
    $n = 1 if $n > 1;
    return $self->{min_val} + $n * ( $self->{max_val} - $self->{min_val} );
}

sub _draw_y_scale {
    my ( $self, $canvas ) = @_;

    my $x_sep = $self->_plot_w;
    my $x_end = $self->{canvas_w};
    my $range = $self->{max_val} - $self->{min_val};
    return if $range <= 0;

    my $min_label_spacing = 16;
    my $plot_h            = $self->_plot_h;
    my $target_lines      = int( $plot_h / $min_label_spacing );
    $target_lines = 2 if $target_lines < 2;
    my $raw_step = $range / $target_lines;

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

    my $decimals =
        ( $step >= 10 )   ? 0
      : ( $step >= 1 )    ? 1
      : ( $step >= 0.1 )  ? 2
      : ( $step >= 0.01 ) ? 3
      :                     4;
    my $fmt = "%.${decimals}f";

    my $first = int( $self->{min_val} / $step ) * $step;
    $first += $step if ( $first + 1e-9 ) < $self->{min_val};
    $first = sprintf( '%.10f', $first ) + 0;

    $canvas->createRectangle(
        $x_sep, 0, $x_end, $self->{canvas_h},
        -fill    => '#ffffff',
        -outline => '#ffffff',
        -tags    => ['scale_bg'],
    );

    $canvas->createLine(
        $x_sep, 0, $x_sep, $self->{canvas_h},
        -fill  => '#c9cdd7',
        -width => 1,
        -tags  => ['scale_border'],
    );

    my $level = $first;
    while ( $level <= $self->{max_val} + 1e-9 ) {
        my $y = $self->value_to_y($level);

        $canvas->createLine(
            0, $y, $x_sep, $y,
            -fill  => '#e0e3eb',
            -width => 1,
            -tags  => ['scale_grid'],
        );

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