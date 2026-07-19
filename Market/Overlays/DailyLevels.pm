package Market::Overlays::DailyLevels;

# =============================================================================
# Market::Overlays::DailyLevels
#
# Dibuja las lineas de Soporte/Resistencia calculadas por
# Indicators::DailyLevels (una vela D + una 4H, coincidencia mas cercana).
# Ambos niveles se calculan SIEMPRE (independiente de la TF activa), por eso
# se pueden mostrar en cualquier temporalidad -- "Show Daily HL" pedido por
# el ingeniero incluye explicitamente verlo desde 1m.
#
# show_daily / show_4h: toggles independientes (Daily y 4H no dependen uno
# del otro, igual patron que el resto de sub-toggles del proyecto).
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_daily_levels';

use constant {
    C_SUPPORT    => '#26a69a',   # verde, mismo tono que el resto del proyecto
    C_RESISTANCE => '#ef5350',   # rojo,  mismo tono que el resto del proyecto
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source      => $args{source},   # Indicators::DailyLevels
        show_daily  => $args{show_daily} // 1,
        show_4h     => $args{show_4h}    // 1,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source} or return;

    $self->_render_tf( $canvas, $scale, 'D',  'Daily', 1.5 ) if $self->{show_daily};
    $self->_render_tf( $canvas, $scale, '4h', '4H',    1   ) if $self->{show_4h};
}

sub _render_tf {
    my ( $self, $canvas, $scale, $tf, $label, $width ) = @_;
    my $lv = $self->{source}->get_level($tf) or return;
    return unless $scale->value_in_range( $lv->{level} );

    my $color = ( $lv->{kind} eq 'support' ) ? C_SUPPORT : C_RESISTANCE;
    my $text  = sprintf( '%s %s %.2f', $label,
        ( $lv->{kind} eq 'support' ? 'Soporte' : 'Resistencia' ), $lv->{level} );

    my $y      = $scale->value_to_y( $lv->{level} );
    my $plot_w = $scale->_plot_w;

    $canvas->createLine( 0, $y, $plot_w, $y,
        -fill => $color, -dash => [ 6, 3 ], -width => $width, -tags => [TAG] );

    my $tid = $canvas->createText( 6, $y - 8,
        -text   => $text,
        -anchor => 'w',
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

1;