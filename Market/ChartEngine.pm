package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine
# Orquestador del sistema de visualizacion.
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);
use Market::Panels::Scales;

use constant {
    MIN_BARS       => 10,
    MAX_BARS       => 800,
    DEFAULT_BARS   => 120,
    PRICE_SCALE_W  => 90,
    TIME_AXIS_H    => 24,
    DRAG_THRESHOLD => 3,
    Y_ZOOM_MIN     => 0.10,
    Y_ZOOM_MAX     => 3.00,
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        %args,

        visible_bars => DEFAULT_BARS,
        offset       => 0,

        zoom_y_auto   => 1,
        y_range_price => undef,

        zoom_y_auto_atr => 1,
        y_range_atr     => undef,

        _render_pending => 0,

        _drag_start_x => undef,
        _drag_start_y => undef,
        _drag_offset  => undef,
        _drag_moved   => 0,

        _drag_y_start     => undef,
        _drag_y_start_atr => undef,

        _mouse_x        => -1,
        _mouse_y        => -1,
        _mouse_y_atr    => -1,
        _mouse_in_price => 0,
        _mouse_in_atr   => 0,

        _scale_price => undef,
        _scale_atr   => undef,

        _price_cross => undef,
        _atr_cross   => undef,

        _ctrl_pressed    => 0,
        _zoom_anchor_idx => undef,
        _zoom_anchor_px  => undef,

        # Modo libre: pan vertical + horizontal sin restricciones de autozoom.
        # En modo auto (free=0) el zoom Y se recalcula solo.
        # En modo manual (free=1) drag izq mueve X e Y libremente,
        # y la rueda ancla al mouse en lugar del borde derecho.
        _free_mode_price => 0,
        _free_mode_atr   => 0,
    };
    bless $self, $class;
    $self->bind_events;
    return $self;
}

# -----------------------------------------------------------------------------
# resize_panels
# -----------------------------------------------------------------------------
sub resize_panels {
    my ( $self, $new_w, $new_ph, $new_ah ) = @_;
    return if $new_w  <= 1 || $new_ph <= 1 || $new_ah <= 1;

    $self->{canvas_w}       = $new_w;
    $self->{canvas_price_h} = $new_ph;
    $self->{canvas_atr_h}   = $new_ah;

    $self->{canvas_price}->configure(
        -scrollregion => [ 0, 0, $new_w, $new_ph ] );
    $self->{canvas_atr}->configure(
        -scrollregion => [ 0, 0, $new_w, $new_ah ] );

    $self->request_render;
}

# -----------------------------------------------------------------------------
# toggle_free_mode
# Devuelve 1 si quedo en modo manual, 0 si quedo en auto.
# -----------------------------------------------------------------------------
sub toggle_free_mode_price {
    my ($self) = @_;
    $self->{_free_mode_price} = $self->{_free_mode_price} ? 0 : 1;

    if ( $self->{_free_mode_price} ) {
        # Al entrar en manual: capturar rango Y actual si no existe
        if ( !$self->{y_range_price} && $self->{_scale_price} ) {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{price_panel}
                ->get_y_range( $self->{market}->get_slice( $s, $e ) );
            $self->{y_range_price} = [ $mn, $mx ];
        }
        $self->{zoom_y_auto} = 0;
    } else {
        # Al volver a auto: resetear
        $self->{zoom_y_auto}   = 1;
        $self->{y_range_price} = undef;
        $self->request_render;
    }
    return $self->{_free_mode_price};
}

sub toggle_free_mode_atr {
    my ($self) = @_;
    $self->{_free_mode_atr} = $self->{_free_mode_atr} ? 0 : 1;

    if ( $self->{_free_mode_atr} ) {
        # Al entrar en manual: capturar rango Y actual si no existe
        if ( !$self->{y_range_atr} && $self->{_scale_atr} ) {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{atr_panel}->get_y_range(
                $self->{indicators}->slice_array( 'atr', $s, $e ) );
            $self->{y_range_atr} = [ $mn, $mx ];
        }
        $self->{zoom_y_auto_atr} = 0;
    } else {
        # Al volver a auto: resetear
        $self->{zoom_y_auto_atr} = 1;
        $self->{y_range_atr}     = undef;
        $self->request_render;
    }
    return $self->{_free_mode_atr};
}

# -----------------------------------------------------------------------------
# compute_window
# -----------------------------------------------------------------------------
sub compute_window {
    my ($self) = @_;

    my $total = $self->{market}->size;
    return ( 0, 0 ) unless $total > 0;

    my $bars         = $self->{visible_bars};
    my $edge_visible = 2;
    my $left_padding = $bars - $edge_visible;
    my $min_offset   = -$left_padding;
    my $max_offset   = $total - $edge_visible;

    $self->{offset} = $min_offset if $self->{offset} < $min_offset;
    $self->{offset} = $max_offset if $self->{offset} > $max_offset;

    return ( $self->{offset}, $self->{offset} + $bars - 1 );
}

sub round {
    my ( $self, $value, $dec ) = @_;
    $dec //= 2;
    return sprintf( "%.${dec}f", $value ) + 0;
}

sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    $self->{canvas_price}->after( 1, sub {
        $self->{_render_pending} = 0;
        $self->render;
    });
}

sub _request_crosshair_draw {
    my ($self) = @_;
    return if $self->{_crosshair_pending};
    $self->{_crosshair_pending} = 1;
    $self->{canvas_price}->after( 1, sub {
        $self->{_crosshair_pending} = 0;
        $self->_draw_crosshair_all;
    });
}

# -----------------------------------------------------------------------------
# render
# -----------------------------------------------------------------------------
sub render {
    my ($self) = @_;

    return if $self->{market}->size == 0;
    my ( $start, $end ) = $self->compute_window;

    my $canv_w  = $self->{canvas_w};
    my $canv_ph = $self->{canvas_price_h};
    my $canv_ah = $self->{canvas_atr_h};
    my $total   = $self->{market}->size;

    my $real_ph = $self->{canvas_price}->height;
    my $real_ah = $self->{canvas_atr}->height;
    my $real_w  = $self->{canvas_price}->width;
    $canv_ph = $real_ph if $real_ph > 1;
    $canv_ah = $real_ah if $real_ah > 1;
    $canv_w  = $real_w  if $real_w  > 1;
    $self->{canvas_w}       = $canv_w;
    $self->{canvas_price_h} = $canv_ph;
    $self->{canvas_atr_h}   = $canv_ah;

    my $safe_start = $start < 0     ? 0        : $start;
    my $safe_end   = $end >= $total ? $total-1 : $end;
    $safe_end = $safe_start if $safe_end < $safe_start;

    my $visible_candles = $self->{market}->get_slice( $safe_start, $safe_end );
    my $visible_atr     = $self->{indicators}->slice_array( 'atr', $start, $end );

    # --- Rango Y precios ---
    my ( $min_p, $max_p );
    if ( $self->{zoom_y_auto} && !$self->{_free_mode_price} ) {
        ( $min_p, $max_p ) = $self->{price_panel}->get_y_range($visible_candles);
    } elsif ( $self->{y_range_price} ) {
        ( $min_p, $max_p ) = @{ $self->{y_range_price} };
    } else {
        ( $min_p, $max_p ) = $self->{price_panel}->get_y_range($visible_candles);
    }
    my $last_visible = $visible_candles->[-1];

    my $scale_price = Market::Panels::Scales->new(
        canvas_w      => $canv_w,
        canvas_h      => $canv_ph,
        price_scale_w => PRICE_SCALE_W,
        visible_bars  => $self->{visible_bars},
        offset        => $start,
        visual_offset => ($start < 0 ? abs($start) : 0),
        min_val       => $min_p,
        max_val       => $max_p,
        padding_top   => 10,
        padding_bot   => TIME_AXIS_H,
        last_close    => $last_visible ? $last_visible->{close} : undef,
    );
    $self->{price_panel}->set_scale($scale_price);
    $self->{_scale_price} = $scale_price;

   # --- Rango Y ATR ---
    my ( $min_a, $max_a );
    if ( $self->{zoom_y_auto_atr} && !$self->{_free_mode_atr} ) {
        ( $min_a, $max_a ) = $self->{atr_panel}->get_y_range($visible_atr);
    } elsif ( $self->{y_range_atr} ) {
        ( $min_a, $max_a ) = @{ $self->{y_range_atr} };
    } else {
        ( $min_a, $max_a ) = $self->{atr_panel}->get_y_range($visible_atr);
    }

    my $last_atr_val;
    for my $v ( reverse @$visible_atr ) {
        if ( defined $v ) { $last_atr_val = $v; last; }
    }

    my $scale_atr = Market::Panels::Scales->new(
        canvas_w      => $canv_w,
        canvas_h      => $canv_ah,
        price_scale_w => PRICE_SCALE_W,
        visible_bars  => $self->{visible_bars},
        offset        => 0,
        visual_offset => ($start < 0 ? abs($start) : 0),
        min_val       => $min_a,
        max_val       => $max_a,
        padding_top   => 14,
        padding_bot   => 6,
        last_atr_val  => $last_atr_val,
    );
    $self->{atr_panel}->set_scale($scale_atr);
    $self->{_scale_atr} = $scale_atr;

    $self->{canvas_price}->delete('price_bg');
    $self->{canvas_price}->delete('candle');
    $self->{canvas_price}->delete('scale_bg');
    $self->{canvas_price}->delete('scale_border');
    $self->{canvas_price}->delete('scale_grid');
    $self->{canvas_price}->delete('scale_label');
    $self->{canvas_price}->delete('last_price');
    $self->{canvas_price}->delete('time_axis');

    $self->{price_panel}->render( $self->{canvas_price}, $visible_candles, $scale_price );
    $self->{price_panel}->render_last_visible_price( $self->{canvas_price} );

    my $anchors = $self->compute_intraday_labels( $start, $end );
    $self->{price_panel}->draw_time_axis( $self->{canvas_price}, $anchors );

    $self->{price_panel}->_init_crosshair_objects;
    $self->_draw_price_cross;

    $self->{canvas_atr}->delete('atr_all');
    $self->{canvas_atr}->delete('scale_bg');
    $self->{canvas_atr}->delete('scale_border');
    $self->{canvas_atr}->delete('scale_grid');
    $self->{canvas_atr}->delete('scale_label');

    $self->{atr_panel}->render( $self->{canvas_atr}, $visible_atr, $scale_atr );
    $self->{atr_panel}->render_last_visible_value( $self->{canvas_atr} );
    $self->{atr_panel}->_init_crosshair;
    $self->_draw_atr_cross;

    $self->_draw_crosshair_all;
}

# -----------------------------------------------------------------------------
# bind_events
# -----------------------------------------------------------------------------
sub bind_events {
    my ($self) = @_;

    my $cp = $self->{canvas_price};
    my $ca = $self->{canvas_atr};

    $cp->configure( -takefocus => 1 );
    $ca->configure( -takefocus => 1 );

    my $toplevel = $cp->toplevel;

    my $hit_test = sub {
        my ( $abs_x, $abs_y ) = @_;

        my $cpx = $cp->rootx; my $cpy = $cp->rooty;
        if (   $abs_x >= $cpx && $abs_x < $cpx + $cp->width
            && $abs_y >= $cpy && $abs_y < $cpy + $cp->height )
        {
            return ( 'price', $abs_x - $cpx, $abs_y - $cpy );
        }

        my $cax = $ca->rootx; my $cay = $ca->rooty;
        if (   $abs_x >= $cax && $abs_x < $cax + $ca->width
            && $abs_y >= $cay && $abs_y < $cay + $ca->height )
        {
            return ( 'atr', $abs_x - $cax, $abs_y - $cay );
        }

        return ( undef, 0, 0 );
    };

    # =========================================================================
    # CTRL press/release: congela anchor de zoom
    # =========================================================================
    for my $key (qw(Control_L Control_R)) {
        $toplevel->bind( "<KeyPress-$key>", sub {
            return if $self->{_ctrl_pressed};
            $self->{_ctrl_pressed} = 1;
            return unless $self->{_scale_price} && $self->{_mouse_x} >= 0;
            my $idx = $self->{_scale_price}->x_to_index( $self->{_mouse_x} );
            $self->{_zoom_anchor_idx} = $idx;
            $self->{_zoom_anchor_px}  = $self->{_mouse_x};
        });
        $toplevel->bind( "<KeyRelease-$key>", sub {
            $self->{_ctrl_pressed}    = 0;
            $self->{_zoom_anchor_idx} = undef;
            $self->{_zoom_anchor_px}  = undef;
        });
    }

    # =========================================================================
    # FOCUSOUT / FocusOut a nivel toplevel:
    # Si el usuario hace Alt+Tab o cambia de ventana mientras CTRL esta
    # presionado, el KeyRelease nunca llega y el crosshair queda congelado.
    # Reseteamos _ctrl_pressed al perder el foco para evitar ese bloqueo.
    # =========================================================================
    $toplevel->bind( '<FocusOut>', sub {
        if ( $self->{_ctrl_pressed} ) {
            $self->{_ctrl_pressed}    = 0;
            $self->{_zoom_anchor_idx} = undef;
            $self->{_zoom_anchor_px}  = undef;
        }
        # Tambien forzamos un redibujado del crosshair para que no quede
        # el _crosshair_pending atascado en 1 por una llamada after huerfana.
        $self->{_crosshair_pending} = 0;
    });

    # =========================================================================
    # RUEDA
    # Modo auto  + sin CTRL : ancla borde derecho
    # Modo auto  + CTRL     : ancla vela bajo el mouse (congelada)
    # Modo manual           : ancla siempre al mouse (igual que CTRL)
    # Shift + Rueda         : zoom vertical
    # =========================================================================
    $toplevel->bind( '<Button-4>', sub {
        my $state = $_[0]->XEvent->s;
        my $ctrl  = ( $state & 4 ) ? 1 : 0;
        my $shift = ( $state & 1 ) ? 1 : 0;

        if ($shift) {
            $self->_vertical_zoom_price(0.9) if $self->{_mouse_in_price};
            $self->_vertical_zoom_atr(0.9)   if $self->{_mouse_in_atr};
        } else {
            # En modo manual la rueda siempre ancla al mouse
        my $use_anchor = $ctrl;

            if ( $use_anchor && !defined $self->{_zoom_anchor_idx}
                && $self->{_scale_price} && $self->{_mouse_x} >= 0 )
            {
                my $idx = $self->{_scale_price}->x_to_index( $self->{_mouse_x} );
                $self->{_ctrl_pressed}    = 1 if $ctrl;
                $self->{_zoom_anchor_idx} = $idx;
                $self->{_zoom_anchor_px}  = $self->{_mouse_x};
            }
            $self->_horizontal_zoom( -1, $use_anchor );
        }
        Tk->break;
    });

    $toplevel->bind( '<Button-5>', sub {
        my $state = $_[0]->XEvent->s;
        my $ctrl  = ( $state & 4 ) ? 1 : 0;
        my $shift = ( $state & 1 ) ? 1 : 0;

        if ($shift) {
            $self->_vertical_zoom_price(1.1) if $self->{_mouse_in_price};
            $self->_vertical_zoom_atr(1.1)   if $self->{_mouse_in_atr};
        } else {
           my $use_anchor = $ctrl;

            if ( $use_anchor && !defined $self->{_zoom_anchor_idx}
                && $self->{_scale_price} && $self->{_mouse_x} >= 0 )
            {
                my $idx = $self->{_scale_price}->x_to_index( $self->{_mouse_x} );
                $self->{_ctrl_pressed}    = 1 if $ctrl;
                $self->{_zoom_anchor_idx} = $idx;
                $self->{_zoom_anchor_px}  = $self->{_mouse_x};
            }
            $self->_horizontal_zoom( 1, $use_anchor );
        }
        Tk->break;
    });

    # =========================================================================
    # MOTION
    # En modo manual NO congelamos el mouse — el crosshair sigue al cursor.
    # En modo CTRL el anchor de zoom se congela pero el crosshair se sigue
    # moviendo (igual que TradingView).
    # =========================================================================
    $toplevel->bind( '<Motion>', sub {
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );

        unless ( defined $panel ) {
            if ( $self->{_mouse_in_price} || $self->{_mouse_in_atr} ) {
                $self->{_mouse_in_price} = 0;
                $self->{_mouse_in_atr}   = 0;
                $self->{price_panel}->hide_crosshair;
                $self->{atr_panel}->hide_crosshair;
            }
            return;
        }

        if ( $panel eq 'price' ) {
            $self->{_mouse_in_price} = 1;
            $self->{_mouse_in_atr}   = 0;
            $self->{_mouse_x}        = $lx;
            $self->{_mouse_y}        = $ly;
        } else {
            $self->{_mouse_in_atr}   = 1;
            $self->{_mouse_in_price} = 0;
            $self->{_mouse_x}        = $lx;
            $self->{_mouse_y_atr}    = $ly;
        }
        $self->_request_crosshair_draw;
    });

    # =========================================================================
    # DRAG IZQUIERDO
    # =========================================================================
    $toplevel->bind( '<ButtonPress-1>', sub {
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;

        $self->{_mouse_in_price} = $panel eq 'price' ? 1 : 0;
        $self->{_mouse_in_atr}   = $panel eq 'atr'   ? 1 : 0;
        $self->{_drag_start_x}   = $lx;
        $self->{_drag_start_y}   = $ly;
        $self->{_drag_offset}    = $self->{offset};
        $self->{_drag_moved}     = 0;
        $self->{_drag_panel}     = $panel;

        # Modo manual precio: inicializar y_range_price si no existe
        if ( $self->{_free_mode_price} && $panel eq 'price'
            && !$self->{y_range_price} && $self->{_scale_price} )
        {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{price_panel}
                ->get_y_range( $self->{market}->get_slice( $s, $e ) );
            $self->{y_range_price} = [ $mn, $mx ];
            $self->{zoom_y_auto}   = 0;
        }

        # Modo manual ATR: inicializar y_range_atr si no existe
        if ( $self->{_free_mode_atr} && $panel eq 'atr'
            && !$self->{y_range_atr} && $self->{_scale_atr} )
        {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{atr_panel}->get_y_range(
                $self->{indicators}->slice_array( 'atr', $s, $e ) );
            $self->{y_range_atr}     = [ $mn, $mx ];
            $self->{zoom_y_auto_atr} = 0;
        }
    });

    $toplevel->bind( '<B1-Motion>', sub {
        return unless $self->{_mouse_in_price} || $self->{_mouse_in_atr};
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );

        if ( !defined $panel ) {
            my $cv = ( $self->{_drag_panel} || 'price' ) eq 'price' ? $cp : $ca;
            $lx = $ev->X - $cv->rootx;
            $ly = $ev->Y - $cv->rooty;
        }

        my $dx = $lx - ( $self->{_drag_start_x} // $lx );
        my $dy = $ly - ( $self->{_drag_start_y} // $ly );

        $self->{_drag_moved} = 1
            if abs($dx) > DRAG_THRESHOLD || abs($dy) > DRAG_THRESHOLD;
        return unless $self->{_drag_moved};

        # --- Pan horizontal (siempre) ---
        my $scale = $self->{_scale_price} // $self->{_scale_atr};
        if ( $scale && $self->{visible_bars} > 0 ) {
            my $bar_w = $scale->_plot_w / $self->{visible_bars};
            if ( $bar_w > 0 ) {
                $self->{offset} =
                    ( $self->{_drag_offset} // 0 ) - int( $dx / $bar_w );
            }
        }

        # --- Pan vertical Y precio (modo manual, panel precios) ---
        if ( $self->{_free_mode_price} && $self->{_mouse_in_price}
            && $self->{y_range_price} && abs($dy) > 0 )
        {
            my ( $mn, $mx ) = @{ $self->{y_range_price} };
            my $plot_h = $self->{canvas_price_h} - 10 - TIME_AXIS_H;
            if ( $plot_h > 0 ) {
                my $delta = $dy / $plot_h * ( $mx - $mn );
                $self->{y_range_price} = [ $mn + $delta, $mx + $delta ];
            }
        }

        # --- Pan vertical Y ATR (modo manual, panel ATR) ---
        if ( $self->{_free_mode_atr} && $self->{_mouse_in_atr}
            && $self->{y_range_atr} && abs($dy) > 0 )
        {
            my ( $mn, $mx ) = @{ $self->{y_range_atr} };
            my $plot_h = $self->{canvas_atr_h} - 6 - 14;  # padding_bot + padding_top
            if ( $plot_h > 0 ) {
                my $delta = $dy / $plot_h * ( $mx - $mn );
                $self->{y_range_atr} = [ $mn + $delta, $mx + $delta ];
            }
        }

        $self->{_drag_start_y} = $ly;
        $self->{_mouse_x}      = $lx;
        $self->request_render;
    });

    # =========================================================================
    # DOBLE CLICK IZQUIERDO
    # =========================================================================
    $toplevel->bind( '<Double-Button-1>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;
        if ( $panel eq 'price' ) {
            $self->{_price_cross} = undef;
            $self->{canvas_price}->delete('price_cross');
        } else {
            $self->{_atr_cross} = undef;
            $self->{canvas_atr}->delete('atr_cross');
        }
    });

    # =========================================================================
    # ESC: borra AMBAS marcas persistentes
    # =========================================================================
    $toplevel->bind( '<Escape>', sub {
        $self->{_price_cross} = undef;
        $self->{_atr_cross}   = undef;
        $self->{canvas_price}->delete('price_cross');
        $self->{canvas_atr}->delete('atr_cross');
    });

    # =========================================================================
    # DRAG DERECHO: zoom/pan vertical
    # =========================================================================
    $toplevel->bind( '<ButtonPress-3>', sub {
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;

        if ( $panel eq 'price' ) {
            $self->{_drag_y_start} = $ly;
            unless ( $self->{y_range_price} ) {
                my ( $s, $e ) = $self->compute_window;
                my ( $mn, $mx ) = $self->{price_panel}
                    ->get_y_range( $self->{market}->get_slice( $s, $e ) );
                $self->{y_range_price} = [ $mn, $mx ];
            }
            $self->{zoom_y_auto} = 0;
        } else {
            $self->{_drag_y_start_atr} = $ly;
            unless ( $self->{y_range_atr} ) {
                my ( $s, $e ) = $self->compute_window;
                my ( $mn, $mx ) = $self->{atr_panel}->get_y_range(
                    $self->{indicators}->slice_array( 'atr', $s, $e ) );
                $self->{y_range_atr} = [ $mn, $mx ];
            }
            $self->{zoom_y_auto_atr} = 0;
        }
    });

    $toplevel->bind( '<B3-Motion>', sub {
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );

        if ( !defined $panel ) {
            my $cv = ( $self->{_drag_panel} || 'price' ) eq 'price' ? $cp : $ca;
            $ly    = $ev->Y - $cv->rooty;
            $panel = $self->{_drag_panel} || 'price';
        }

        if ( $panel eq 'price' ) {
            my $dy = $ly - ( $self->{_drag_y_start} // $ly );
            $self->{_drag_y_start} = $ly;
            $self->_vertical_drag($dy);
        } else {
            my $dy = $ly - ( $self->{_drag_y_start_atr} // $ly );
            $self->{_drag_y_start_atr} = $ly;
            $self->_vertical_drag_atr($dy);
        }
    });

    $toplevel->bind( '<Double-Button-3>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;
        if ( $panel eq 'price' ) {
            $self->{zoom_y_auto}   = 1;
            $self->{y_range_price} = undef;
        } else {
            $self->{zoom_y_auto_atr} = 1;
            $self->{y_range_atr}     = undef;
        }
        $self->request_render;
    });

    # =========================================================================
    # RESIZE
    # =========================================================================
    $toplevel->bind( '<Configure>', sub {
        my $new_w  = $self->{canvas_price}->width;
        my $new_h  = $self->{canvas_price}->height;
        my $new_ah = $self->{canvas_atr}->height;

        return if $new_w  <= 1 || $new_h <= 1;
        return if $new_w  == $self->{canvas_w}
               && $new_h  == $self->{canvas_price_h}
               && $new_ah == $self->{canvas_atr_h};

        $self->{canvas_w}       = $new_w;
        $self->{canvas_price_h} = $new_h;
        $self->{canvas_atr_h}   = $new_ah;
        $self->{canvas_price}->configure(
            -scrollregion => [ 0, 0, $new_w, $new_h ] );
        $self->{canvas_atr}->configure(
            -scrollregion => [ 0, 0, $new_w, $new_ah ] );
        $self->request_render;
    });
}

# -----------------------------------------------------------------------------
# _horizontal_zoom
# $ctrl_or_anchor : 0 = anclar borde derecho
#                   1 = anclar vela bajo el mouse
# -----------------------------------------------------------------------------
sub _horizontal_zoom {
    my ( $self, $dir, $ctrl_or_anchor ) = @_;
    my $old = $self->{visible_bars};
    my $new = ( $dir > 0 ) ? int( $old * 1.15 ) : int( $old / 1.15 );
    $new = MIN_BARS if $new < MIN_BARS;
    $new = MAX_BARS if $new > MAX_BARS;
    return if $new == $old;

    if ( $ctrl_or_anchor && defined $self->{_zoom_anchor_idx}
        && $self->{_scale_price} )
    {
        my $anchor_idx = $self->{_zoom_anchor_idx};
        my $anchor_px  = $self->{_zoom_anchor_px};
        my $bar_w_new  = $self->{_scale_price}->_plot_w / $new;
        $self->{visible_bars} = $new;
        $self->{offset} = $anchor_idx - int( $anchor_px / $bar_w_new );
    } else {
        my $anchor = $self->{offset} + $old - 1;
        $self->{visible_bars} = $new;
        $self->{offset}       = $anchor - ( $new - 1 );
    }


    $self->request_render;
}

# -----------------------------------------------------------------------------
# _clamp_price_range
# -----------------------------------------------------------------------------
sub _clamp_price_range {
    my ( $self, $new_mn, $new_mx ) = @_;
    my $range = $new_mx - $new_mn;
    return ( $new_mn, $new_mx ) if $range <= 0;

    my ( $s, $e ) = $self->compute_window;
    my $vis = $self->{market}->get_slice( $s, $e );
    return ( $new_mn, $new_mx ) unless $vis && @$vis;

    my $data_max = $vis->[0]{high};
    my $data_min = $vis->[0]{low};
    for my $c (@$vis) {
        $data_max = $c->{high} if $c->{high} > $data_max;
        $data_min = $c->{low}  if $c->{low}  < $data_min;
    }
    my $data_range = $data_max - $data_min;
    $data_range = 1 if $data_range < 1;
    my $margin = $data_range * 0.10;

    my $max_range = $data_range * Y_ZOOM_MAX;
    if ( $range > $max_range ) {
        my $center = ( $new_mn + $new_mx ) / 2;
        $range  = $max_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    my $min_range = $data_range * Y_ZOOM_MIN;
    if ( $range < $min_range ) {
        my $center = ( $new_mn + $new_mx ) / 2;
        $range  = $min_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    if ( $new_mx < $data_min + $margin ) {
        $new_mx = $data_min + $margin;
        $new_mn = $new_mx - $range;
    }
    if ( $new_mn > $data_max - $margin ) {
        $new_mn = $data_max - $margin;
        $new_mx = $new_mn + $range;
    }

    return ( $new_mn, $new_mx );
}

# -----------------------------------------------------------------------------
# _clamp_atr_range
# -----------------------------------------------------------------------------
sub _clamp_atr_range {
    my ( $self, $new_mn, $new_mx ) = @_;
    my $range = $new_mx - $new_mn;
    return ( $new_mn, $new_mx ) if $range <= 0;

    my ( $s, $e ) = $self->compute_window;
    my $vis_atr = $self->{indicators}->slice_array( 'atr', $s, $e );
    my @valid   = grep { defined $_ } @$vis_atr;
    return ( $new_mn, $new_mx ) unless @valid;

    my $data_max   = $valid[0];
    for my $v (@valid) { $data_max = $v if $v > $data_max; }
    my $data_range = $data_max < 0.1 ? 0.1 : $data_max;
    my $margin     = $data_range * 0.5;

    my $max_range = $data_range * Y_ZOOM_MAX;
    if ( $range > $max_range ) {
        my $center = ( $new_mn + $new_mx ) / 2;
        $range  = $max_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    my $min_range = $data_range * Y_ZOOM_MIN;
    if ( $range < $min_range ) {
        my $center = ( $new_mn + $new_mx ) / 2;
        $range  = $min_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    if ( $new_mn < 0 ) {
        $new_mx -= $new_mn;
        $new_mn = 0;
    }

    if ( $new_mx > $data_max + $margin && $range >= $max_range ) {
        $new_mx = $data_max + $margin;
        $new_mn = $new_mx - $range;
        $new_mn = 0 if $new_mn < 0;
    }
    return ( $new_mn, $new_mx );
}

# -----------------------------------------------------------------------------
# _draw_price_cross
# -----------------------------------------------------------------------------
sub _draw_price_cross {
    my ($self) = @_;
    my $cross  = $self->{_price_cross};
    my $canvas = $self->{canvas_price};
    my $scale  = $self->{_scale_price};

    $canvas->delete('price_cross');
    return unless defined $cross && $scale;

    my $color = '#2962ff';
    my $x     = $scale->index_to_center_x( $cross->{idx} );
    my $y     = $scale->value_to_y( $cross->{value} );
    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};
    my $y_sep = $scale->{canvas_h} - $scale->{padding_bot};

    my $idx_in_view = (
        $cross->{idx} >= $scale->{offset}
        && $cross->{idx} < $scale->{offset} + $scale->{visible_bars}
        && $x >= 0 && $x <= $x_sep
    );

    if ($idx_in_view) {
        $canvas->createLine( $x, 0, $x, $y_sep,
            -fill => $color, -dash => [4,3], -width => 1,
            -tags => ['price_cross'] );
    }

    if ( $scale->value_in_range( $cross->{value} ) ) {
        $canvas->createLine( 0, $y, $x_sep, $y,
            -fill => $color, -dash => [4,3], -width => 1,
            -tags => ['price_cross'] );
        $canvas->createRectangle( $x_sep+1, $y-9, $x_end-1, $y+9,
            -fill => $color, -outline => $color, -tags => ['price_cross'] );
        $canvas->createText( $x_sep + ($x_end-$x_sep)/2, $y,
            -text => sprintf('%.2f', $cross->{value}), -fill => '#ffffff',
            -anchor => 'center', -font => 'TkFixedFont 8 bold',
            -tags => ['price_cross'] );
    }

    if ($idx_in_view) {
        my $candle = $self->{market}->get_candle( $cross->{idx} );
        if ($candle) {
            my $time_lbl = _format_time_for_axis( $candle->{time} );
            my $w = length($time_lbl) * 5 + 12;
            $canvas->createRectangle( $x-$w/2, $y_sep+1, $x+$w/2, $y_sep+17,
                -fill => $color, -outline => $color, -tags => ['price_cross'] );
            $canvas->createText( $x, $y_sep+9,
                -text => $time_lbl, -fill => '#ffffff',
                -anchor => 'center', -font => 'TkFixedFont 8 bold',
                -tags => ['price_cross'] );
        }
    }

    $canvas->raise('price_cross');
}

# -----------------------------------------------------------------------------
# _draw_atr_cross
# -----------------------------------------------------------------------------
sub _draw_atr_cross {
    my ($self) = @_;
    my $cross  = $self->{_atr_cross};
    my $canvas = $self->{canvas_atr};
    my $scale  = $self->{_scale_atr};

    $canvas->delete('atr_cross');
    return unless defined $cross && $scale;

    my $color   = '#b71c1c';
    my $rel_idx = $cross->{idx} - $self->{offset};
    my $x       = $scale->index_to_center_x($rel_idx);
    my $y       = $scale->value_to_y( $cross->{value} );
    my $x_sep   = $scale->_plot_w;
    my $x_end   = $scale->{canvas_w};

    my $idx_in_view = (
        $rel_idx >= 0 && $rel_idx < $scale->{visible_bars}
        && $x >= 0 && $x <= $x_sep
    );

    if ($idx_in_view) {
        $canvas->createLine( $x, 0, $x, $scale->{canvas_h},
            -fill => $color, -dash => [4,3], -width => 1,
            -tags => ['atr_cross'] );
    }

    if ( $scale->value_in_range( $cross->{value} ) ) {
        $canvas->createLine( 0, $y, $x_sep, $y,
            -fill => $color, -dash => [4,3], -width => 1,
            -tags => ['atr_cross'] );
        $canvas->createRectangle( $x_sep+1, $y-9, $x_end-1, $y+9,
            -fill => $color, -outline => $color, -tags => ['atr_cross'] );
        $canvas->createText( $x_sep + ($x_end-$x_sep)/2, $y,
            -text => sprintf('%.4f', $cross->{value}), -fill => '#ffffff',
            -anchor => 'center', -font => 'TkFixedFont 8 bold',
            -tags => ['atr_cross'] );
    }

    $canvas->raise('atr_cross');
}

sub _format_time_for_axis {
    my ($iso) = @_;
    return '' unless defined $iso;
    if ( $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/ ) {
        return sprintf( '%s/%s %s:%s', $3, $2, $4, $5 );
    }
    return $iso;
}

sub _vertical_drag {
    my ( $self, $dy ) = @_;
    return unless $self->{y_range_price};
    my ( $mn, $mx ) = @{ $self->{y_range_price} };
    my $plot_h = $self->{canvas_price_h} - 10 - TIME_AXIS_H;
    return if $plot_h <= 0;

    # dy negativo = mouse sube = zoom-in (rango se achica)
    # dy positivo = mouse baja = zoom-out (rango se expande)
    my $factor = 1.0 - ( $dy / $plot_h );
    $factor = 0.05 if $factor < 0.05;
    $factor = 5.0  if $factor > 5.0;

    my $mid = ( $mn + $mx ) / 2;
    my $half = ( $mx - $mn ) / 2 * $factor;
    my ( $new_mn, $new_mx ) = $self->_clamp_price_range( $mid - $half, $mid + $half );
    $self->{y_range_price} = [ $new_mn, $new_mx ];
    $self->request_render;
}

sub _vertical_drag_atr {
    my ( $self, $dy ) = @_;
    return unless $self->{y_range_atr};
    my ( $mn, $mx ) = @{ $self->{y_range_atr} };
    my $plot_h = $self->{canvas_atr_h};
    return if $plot_h <= 0;

    # dy negativo = mouse sube = zoom-in
    # dy positivo = mouse baja = zoom-out
    my $factor = 1.0 - ( $dy / $plot_h );
    $factor = 0.05 if $factor < 0.05;
    $factor = 5.0  if $factor > 5.0;

    my $mid = ( $mn + $mx ) / 2;
    my $half = ( $mx - $mn ) / 2 * $factor;
    my ( $new_mn, $new_mx ) = $self->_clamp_atr_range( $mid - $half, $mid + $half );
    $self->{y_range_atr} = [ $new_mn, $new_mx ];
    $self->request_render;
}

sub _vertical_zoom_price {
    my ( $self, $factor ) = @_;
    $self->{zoom_y_auto} = 0;
    my ( $mn, $mx );
    if ( $self->{y_range_price} ) {
        ( $mn, $mx ) = @{ $self->{y_range_price} };
    } else {
        my ( $s, $e ) = $self->compute_window;
        ( $mn, $mx ) = $self->{price_panel}->get_y_range(
            $self->{market}->get_slice($s,$e) );
    }
    my $mid  = ( $mn + $mx ) / 2;
    my $half = ( $mx - $mn ) / 2 * $factor;
    my ( $new_mn, $new_mx ) = $self->_clamp_price_range( $mid - $half, $mid + $half );
    $self->{y_range_price} = [ $new_mn, $new_mx ];
    $self->request_render;
}

sub _vertical_zoom_atr {
    my ( $self, $factor ) = @_;
    $self->{zoom_y_auto_atr} = 0;
    my ( $mn, $mx );
    if ( $self->{y_range_atr} ) {
        ( $mn, $mx ) = @{ $self->{y_range_atr} };
    } else {
        my ( $s, $e ) = $self->compute_window;
        ( $mn, $mx ) = $self->{atr_panel}->get_y_range(
            $self->{indicators}->slice_array( 'atr', $s, $e ) );
    }
    my $mid  = ( $mn + $mx ) / 2;
    my $half = ( $mx - $mn ) / 2 * $factor;
    my ( $new_mn, $new_mx ) = $self->_clamp_atr_range( $mid - $half, $mid + $half );
    $self->{y_range_atr} = [ $new_mn, $new_mx ];
    $self->request_render;
}

# -----------------------------------------------------------------------------
# _draw_crosshair_all
# Modo CTRL   : crosshair en pixel congelado (anchor_px), sin snap
# Modo manual : crosshair en pixel exacto del mouse, sin snap a vela
# Modo auto   : crosshair snapeado al centro de la vela mas cercana
# -----------------------------------------------------------------------------
sub _draw_crosshair_all {
    my ($self) = @_;

    my $x;
    if ( $self->{_ctrl_pressed} && defined $self->{_zoom_anchor_px} ) {
        $x = $self->{_zoom_anchor_px};   # congelado por CTRL
    } else {
        $x = $self->{_mouse_x};
    }

    my $y     = $self->{_mouse_y};
    my $y_atr = $self->{_mouse_y_atr};
    return if !defined $x || $x < 0;

    my $candle_info;
    if ( $self->{_scale_price} ) {
        my $idx = $self->{_scale_price}->x_to_index($x);
        $candle_info = $self->{market}->get_candle($idx);
    }

    if ( $self->{_scale_price} && $self->{price_panel}{_cross_ready} ) {
        if ( $self->{_mouse_in_price} || $self->{_ctrl_pressed} ) {
            my $snap_idx = $self->{_scale_price}->x_to_index($x);
            # Modo manual o CTRL: pixel exacto sin snap
            # Modo auto: snap al centro de la vela
            my $snap_x = ( $self->{_free_mode_price} || $self->{_ctrl_pressed} )
                ? $x
                : $self->{_scale_price}->index_to_center_x($snap_idx);
            $self->{price_panel}->draw_crosshair( $snap_x, $y, $candle_info );
        } elsif ( $self->{_mouse_in_atr} ) {
            my $snap_idx = $self->{_scale_price}->x_to_index($x);
            my $snap_x   = $self->{_scale_price}->index_to_center_x($snap_idx);
            $self->{price_panel}->show_vline_only($snap_x);
            $self->{price_panel}->show_ohlcv_info($candle_info) if $candle_info;
        } else {
            $self->{price_panel}->hide_crosshair;
        }
    }

    if ( $self->{_scale_atr} && $self->{atr_panel}{_cross_ready} ) {
        if ( $self->{_mouse_in_atr} ) {
            my $snap_idx = $self->{_scale_atr}->x_to_index($x);
            my $snap_x   = $self->{_scale_atr}->index_to_center_x($snap_idx);
            $self->{atr_panel}->draw_crosshair( $snap_x, $y_atr );
        } elsif ( $self->{_mouse_in_price} || $self->{_ctrl_pressed} ) {
            my $snap_idx = $self->{_scale_atr}->x_to_index($x);
            my $snap_x   = $self->{_free_mode_atr}
                ? $x
                : $self->{_scale_atr}->index_to_center_x($snap_idx);
            $self->{atr_panel}->show_vline_only($snap_x);
        } else {
            $self->{atr_panel}->hide_crosshair;
        }
    }
}

sub set_timeframe {
    my ( $self, $tf ) = @_;
    $self->{market}->set_timeframe($tf);
    $self->{indicators}->reset_all;
    $self->{indicators}->rebuild_all( $self->{market} );
    $self->reset_view;
    $self->request_render;
}

sub reset_view {
    my ($self) = @_;
    $self->{visible_bars}     = DEFAULT_BARS;
    $self->{zoom_y_auto}      = 1;
    $self->{y_range_price}    = undef;
    $self->{zoom_y_auto_atr}  = 1;
    $self->{y_range_atr}      = undef;
    $self->{_scale_price}     = undef;
    $self->{_scale_atr}       = undef;
    $self->{_price_cross}     = undef;
    $self->{_atr_cross}       = undef;
    $self->{_ctrl_pressed}    = 0;
    $self->{_zoom_anchor_idx} = undef;
    $self->{_zoom_anchor_px}  = undef;

    my $total = $self->{market}->size;
    $self->{offset} = $total - DEFAULT_BARS;
    $self->{offset} = 0 if $self->{offset} < 0;
}

sub compute_intraday_labels {
    my ( $self, $start, $end ) = @_;

    my $visible = $end - $start + 1;
    return [] if $visible <= 0;

    my %tf_min   = ( '1m' => 1, '5m' => 5, '15m' => 15 );
    my $tf       = $self->{market}->get_timeframe;
    my $bar_min  = $tf_min{$tf} // 1;

    my @nice     = ( 1, 2, 5, 10, 15, 20, 30, 60, 120, 240, 360, 720, 1440 );
    my $step_min = $nice[-1];
    for my $s (@nice) {
        next if $s < $bar_min;
        if ( $visible / ( $s / $bar_min ) <= 12 ) { $step_min = $s; last; }
    }

    my $min_gap = int( $step_min / $bar_min / 2 );
    $min_gap = 1 if $min_gap < 1;

    my @DAY_ABBR        = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @result;
    my $last_placed_idx = -999999;
    my $last_slot       = -1;
    my $last_day        = -1;
    my $first_bar       = 1;

    for my $i ( $start .. $end ) {
        my $c = $self->{market}->get_candle($i);
        next unless $c;
        next unless defined $c->{time}
            && $c->{time} =~ /\d{4}-\d{2}-(\d{2})T(\d{2}):(\d{2})/;

        my ( $mday, $hour, $min ) = ( $1+0, $2+0, $3+0 );
        my $cur_slot = int( ( $hour * 60 + $min ) / $step_min );

        if ($first_bar) {
            push @result, {
                index => $i,
                label => sprintf('%d:%02d', $hour, $min),
                ts    => $c->{ts}
            };
            $last_placed_idx = $i;
            $last_day        = $mday;
            $last_slot       = $cur_slot;
            $first_bar       = 0;
            next;
        }

        my $day_change  = ( $mday != $last_day );
        my $slot_change = ( $cur_slot != $last_slot );
        $last_day  = $mday;
        $last_slot = $cur_slot;

        next unless $day_change || $slot_change;
        next if $i - $last_placed_idx < $min_gap;

        my $label;
        if ($day_change) {
            my $wday = ( gmtime( $c->{ts} ) )[6];
            $label = $DAY_ABBR[$wday] . ' ' . $mday;
        } else {
            $label = sprintf( '%d:%02d',
                int( $cur_slot * $step_min / 60 ),
                ( $cur_slot * $step_min ) % 60 );
        }

        push @result, { index => $i, label => $label, ts => $c->{ts}, is_day => $day_change };
        $last_placed_idx = $i;
    }

    return \@result;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ( $start, $end ) = $self->compute_window;
    my $slice = $self->{market}->get_slice( $start, $end );
    return [ map { $_->{ts} } @$slice ];
}

1;