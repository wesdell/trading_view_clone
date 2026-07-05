package Market::ChartEngine;

use strict;
use warnings;
use POSIX qw(floor);
use Market::Panels::Scales;
use Market::Overlays::LabelPlacer;

use constant {
    MIN_BARS       => 2,
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

        _render_pending    => 0,
        _crosshair_pending => 0,

        _drag_start_x => undef,
        _drag_start_y => undef,
        _drag_offset  => undef,
        _drag_moved   => 0,
        _drag_panel   => undef,

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

        _free_mode_price => 0,
        _free_mode_atr   => 0,

        # Callbacks para sincronizar botones de toolbar con estado interno
        _cb_mode_price => undef,
        _cb_mode_atr   => undef,

        # Modo "seleccionar vela" (iniciar Replay con clic en vez de TextField)
        _pick_mode => 0,
        _pick_cb   => undef,

        # Marcador visual del punto de inicio del Replay (linea + fecha/hora)
        _replay_start_index => undef,
        _replay_start_label => undef,

        # Drag en regleta Y
        _scale_drag_panel   => undef,
        _scale_drag_start_y => undef,

        # Flag para ignorar <Configure> durante resize manual del separador
        _resizing_panels => 0,

        # Drag de la regleta de precios anclado en pasos de 0.25 (tick real)
        _scale_drag_base_mn => undef,
        _scale_drag_base_mx => undef,
    };
    bless $self, $class;
    $self->bind_events;
    return $self;
}

use constant PRICE_TICK => 0.25;   # tick de mercado para zoom de la regleta

# -----------------------------------------------------------------------------
# set_mode_callbacks
# Registra funciones que se llaman cuando cambia el modo precio/ATR.
# Permite sincronizar los botones de la toolbar con el estado interno.
# $cb_price y $cb_atr reciben (1) si quedó en manual, (0) si quedó en auto.
# -----------------------------------------------------------------------------
sub set_mode_callbacks {
    my ( $self, $cb_price, $cb_atr ) = @_;
    $self->{_cb_mode_price} = $cb_price;
    $self->{_cb_mode_atr}   = $cb_atr;
}

# -----------------------------------------------------------------------------
# _notify_mode_price / _notify_mode_atr  (privados)
# Disparan el callback si está registrado.
# -----------------------------------------------------------------------------
sub _notify_mode_price {
    my ( $self, $is_free ) = @_;
    $self->{_cb_mode_price}->($is_free) if $self->{_cb_mode_price};
}

sub _notify_mode_atr {
    my ( $self, $is_free ) = @_;
    $self->{_cb_mode_atr}->($is_free) if $self->{_cb_mode_atr};
}

# -----------------------------------------------------------------------------
# begin_candle_pick / cancel_candle_pick / is_picking
# Modo "seleccionar vela": mientras esta activo, el proximo clic izquierdo
# sobre el panel de precio NO arrastra el grafico; en su lugar mapea la X del
# clic a un indice de vela (mismo mapeo X->indice que usa el crosshair) y llama
# $cb->($index, $candle). Lo usa la barra de Replay para elegir la vela de
# inicio con un clic. Un clic fuera del area de velas NO inicia y mantiene el
# modo activo. Cambia el cursor a 'crosshair' como pista visual.
# -----------------------------------------------------------------------------
sub begin_candle_pick {
    my ( $self, $cb ) = @_;
    $self->{_pick_mode} = 1;
    $self->{_pick_cb}   = $cb;
    eval { $self->{canvas_price}->configure( -cursor => 'crosshair' ) };
}

sub cancel_candle_pick {
    my ($self) = @_;
    return unless $self->{_pick_mode};
    $self->{_pick_mode} = 0;
    $self->{_pick_cb}   = undef;
    eval { $self->{canvas_price}->configure( -cursor => '' ) };
}

sub is_picking { return $_[0]->{_pick_mode} ? 1 : 0; }

# -----------------------------------------------------------------------------
# set_replay_start_marker / clear_replay_start_marker
# Marca en el grafico la vela desde la que arranco el Replay: una linea
# vertical + un label con su fecha/hora. Sirve como confirmacion visual de que
# el replay inicia EXACTAMENTE en la vela elegida con el clic (el indice es
# global en la TF activa; se limpia al salir del replay o cambiar de TF).
# -----------------------------------------------------------------------------
sub set_replay_start_marker {
    my ( $self, $index, $label ) = @_;
    $self->{_replay_start_index} = $index;
    $self->{_replay_start_label} = $label;

    # Encuadre (spec 18): la vela de inicio queda al borde IZQUIERDO, con un
    # pequeno margen, y el espacio a la derecha se ira llenando conforme avanza
    # el replay. follow_replay_pointer respeta este offset mientras el puntero
    # siga dentro de la ventana (solo hace scroll cuando se sale por la derecha).
    my $pad = 3;
    $self->{offset} = $index - $pad;

    $self->request_render;
}

sub clear_replay_start_marker {
    my ($self) = @_;
    return unless defined $self->{_replay_start_index};
    $self->{_replay_start_index} = undef;
    $self->{_replay_start_label} = undef;
    $self->{canvas_price}->delete('replay_marker');
    $self->request_render;
}

# -----------------------------------------------------------------------------
# resize_panels — llamado desde market.pl al arrastrar el separador ATR
# -----------------------------------------------------------------------------
sub resize_panels {
    my ( $self, $new_w, $new_ph, $new_ah ) = @_;
    return if $new_w <= 1 || $new_ph <= 1 || $new_ah <= 1;

    $self->{_resizing_panels} = 1;
    $self->{canvas_w}         = $new_w;
    $self->{canvas_price_h}   = $new_ph;
    $self->{canvas_atr_h}     = $new_ah;

    $self->{canvas_price}->configure(
        -scrollregion => [ 0, 0, $new_w, $new_ph ] );
    $self->{canvas_atr}->configure(
        -scrollregion => [ 0, 0, $new_w, $new_ah ] );

    $self->request_render;
    $self->{canvas_price}->after( 50, sub { $self->{_resizing_panels} = 0 } );
}

# -----------------------------------------------------------------------------
# toggle_free_mode_price / toggle_free_mode_atr
# -----------------------------------------------------------------------------
sub toggle_free_mode_price {
    my ($self) = @_;
    $self->{_free_mode_price} = $self->{_free_mode_price} ? 0 : 1;

    if ( $self->{_free_mode_price} ) {
        if ( !$self->{y_range_price} && $self->{_scale_price} ) {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{price_panel}
                ->get_y_range( $self->{market}->get_slice( $s, $e ) );
            $self->{y_range_price} = [ $mn, $mx ];
        }
        $self->{zoom_y_auto} = 0;
    } else {
        $self->{zoom_y_auto}   = 1;
        $self->{y_range_price} = undef;
        $self->request_render;
    }
    $self->_notify_mode_price( $self->{_free_mode_price} );
    return $self->{_free_mode_price};
}

sub toggle_free_mode_atr {
    my ($self) = @_;
    $self->{_free_mode_atr} = $self->{_free_mode_atr} ? 0 : 1;

    if ( $self->{_free_mode_atr} ) {
        if ( !$self->{y_range_atr} && $self->{_scale_atr} ) {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{atr_panel}->get_y_range(
                $self->{indicators}->slice_array( 'atr', $s, $e ) );
            $self->{y_range_atr} = [ $mn, $mx ];
        }
        $self->{zoom_y_auto_atr} = 0;
    } else {
        $self->{zoom_y_auto_atr} = 1;
        $self->{y_range_atr}     = undef;
        $self->request_render;
    }
    $self->_notify_mode_atr( $self->{_free_mode_atr} );
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
    my $min_offset   = -( $bars - $edge_visible );
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
    my $total = $self->{market}->size;

    my $canv_w  = $self->{canvas_price}->width;
    my $canv_ph = $self->{canvas_price}->height;
    my $canv_ah = $self->{canvas_atr}->height;
    $canv_w  = $self->{canvas_w}       if $canv_w  <= 1;
    $canv_ph = $self->{canvas_price_h} if $canv_ph <= 1;
    $canv_ah = $self->{canvas_atr_h}   if $canv_ah <= 1;
    $self->{canvas_w}       = $canv_w;
    $self->{canvas_price_h} = $canv_ph;
    $self->{canvas_atr_h}   = $canv_ah;

    # El offset puede ser fraccionario (zoom anclado con Ctrl). Para cortar el
    # dataset se usan limites ENTEROS (floor del borde izquierdo, +1 vela de
    # margen a la derecha para cubrir la barra parcial), mientras que la
    # geometria (Scales) sigue usando el offset fraccionario para que la vela
    # bajo el cursor quede fija al hacer zoom.
    my $islice_start = floor($start);
    $islice_start = 0 if $islice_start < 0;
    my $islice_end = floor($end) + 1;
    $islice_end = $total - 1 if $islice_end > $total - 1;
    $islice_end = $islice_start if $islice_end < $islice_start;

    my $visible_candles = $self->{market}->get_slice( $islice_start, $islice_end );
    my $visible_atr     = $self->{indicators}->slice_array( 'atr', $islice_start, $islice_end );

    my ( $min_p, $max_p );
    if ( $self->{zoom_y_auto} && !$self->{_free_mode_price} ) {
        ( $min_p, $max_p ) = $self->{price_panel}->get_y_range($visible_candles);
    } elsif ( $self->{y_range_price} ) {
        ( $min_p, $max_p ) = @{ $self->{y_range_price} };
    } else {
        ( $min_p, $max_p ) = $self->{price_panel}->get_y_range($visible_candles);
    }
    my $last_visible = $visible_candles->[-1];

    # Escala de Precio (SIN visual_offset)
    my $scale_price = Market::Panels::Scales->new(
        canvas_w      => $canv_w,
        canvas_h      => $canv_ph,
        price_scale_w => PRICE_SCALE_W,
        visible_bars  => $self->{visible_bars},
        offset        => $start,
        slice_start   => $islice_start,
        min_val       => $min_p,
        max_val       => $max_p,
        padding_top   => 10,
        padding_bot   => TIME_AXIS_H,
        last_close    => $last_visible ? $last_visible->{close} : undef,
    );
    $self->{price_panel}->set_scale($scale_price);
    $self->{_scale_price} = $scale_price;

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

    # Escala de ATR (SIN visual_offset)
    my $scale_atr = Market::Panels::Scales->new(
        canvas_w      => $canv_w,
        canvas_h      => $canv_ah,
        price_scale_w => PRICE_SCALE_W,
        visible_bars  => $self->{visible_bars},
        offset        => $start,
        slice_start   => $islice_start,
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

    # Overlays (Etapa 2, Fase 2): reutilizan el mismo $scale_price ya
    # construido arriba -- nunca crean una escala propia. $self->{overlays}
    # es opcional para no romper compatibilidad si algun consumidor de
    # ChartEngine no lo provee.
    #
    # Anti-solape de etiquetas: se crea un LabelPlacer sembrado con las cajas
    # (cuerpo+mecha) de las velas visibles como OBSTACULOS. Los overlays encolan
    # sus etiquetas en el placer en vez de dibujarlas al vuelo; al final se
    # llama flush() para colocarlas evitando velas y otras etiquetas, por orden
    # de prioridad. Se borran las etiquetas del frame anterior antes de encolar.
    $self->{canvas_price}->delete('labels');
    my $placer;
    if ( $self->{overlays} ) {
        my $bar_w = $scale_price->_plot_w / $scale_price->{visible_bars};
        my $hw    = $bar_w / 2 + 1;
        my @obst;
        my $gi = $islice_start;
        for my $c (@$visible_candles) {
            my $cx = $scale_price->index_to_center_x($gi);
            push @obst, [
                $cx - $hw, $scale_price->value_to_y( $c->{high} ),
                $cx + $hw, $scale_price->value_to_y( $c->{low} ),
            ];
            $gi++;
        }
        $placer = Market::Overlays::LabelPlacer->new(
            obstacles => \@obst,
            plot_w    => $scale_price->_plot_w,
            plot_h    => $canv_ph,
        );
        $self->{overlays}->render_all( $self->{canvas_price}, $scale_price, $placer );
    }

    # Z-order: las ZONAS de FVG y OB deben quedar DETRAS de las velas (no
    # taparlas). Los overlays se dibujan despues de las velas, asi que aqui se
    # empujan sus rectangulos por debajo del tag 'candle'. Se baja FVG primero y
    # OB despues -> orden final (de atras a adelante): FVG, OB, velas; asi el OB
    # mantiene prioridad visual sobre el FVG (spec 18/29). Los chips y lineas
    # estructurales/liquidez (otros tags) permanecen al frente. Se protege con
    # if/eval por si el tag de referencia aun no existe en un frame vacio.
    my $cpz = $self->{canvas_price};
    my @candle_ids = $cpz->find( withtag => 'candle' );
    if (@candle_ids) {
        eval { $cpz->lower( 'smc_fvg_zone', 'candle' ) };
        eval { $cpz->lower( 'smc_ob_zone',  'candle' ) };
    }

    # Colocar TODAS las etiquetas encoladas (por encima de velas/lineas),
    # resolviendo colisiones contra velas y entre si segun prioridad.
    $placer->flush( $self->{canvas_price}, 'labels' ) if $placer;

    $self->{price_panel}->render_last_visible_price( $self->{canvas_price} );

    my $anchors = $self->compute_intraday_labels( $islice_start, $islice_end );
    $self->{price_panel}->draw_time_axis( $self->{canvas_price}, $anchors );
    $self->{price_panel}->_init_crosshair_objects;

    # Marcador de inicio de Replay (linea vertical + fecha/hora de la vela).
    $self->{canvas_price}->delete('replay_marker');
    if ( defined $self->{_replay_start_index} ) {
        my $si = $self->{_replay_start_index};
        if ( $si >= $islice_start && $si <= $islice_end ) {
            my $mx = $scale_price->index_to_center_x($si);
            $self->{canvas_price}->createLine(
                $mx, 0, $mx, $canv_ph,
                -fill => '#8e24aa', -width => 1, -dash => [3, 3],
                -tags => ['replay_marker'] );
            if ( defined $self->{_replay_start_label} ) {
                my $tid = $self->{canvas_price}->createText(
                    $mx + 4, 6,
                    -text   => 'Inicio replay: ' . $self->{_replay_start_label},
                    -anchor => 'nw', -fill => '#8e24aa',
                    -font   => 'TkDefaultFont 8 bold',
                    -tags   => ['replay_marker'] );
                my @bb = $self->{canvas_price}->bbox($tid);
                if (@bb) {
                    my $rid = $self->{canvas_price}->createRectangle(
                        $bb[0] - 2, $bb[1] - 1, $bb[2] + 2, $bb[3] + 1,
                        -fill => '#ffffff', -outline => '#8e24aa',
                        -tags => ['replay_marker'] );
                    $self->{canvas_price}->lower( $rid, $tid );
                }
            }
        }
    }

    $self->{canvas_atr}->delete('atr_all');
    $self->{canvas_atr}->delete('scale_bg');
    $self->{canvas_atr}->delete('scale_border');
    $self->{canvas_atr}->delete('scale_grid');
    $self->{canvas_atr}->delete('scale_label');

    $self->{atr_panel}->render( $self->{canvas_atr}, $visible_atr, $scale_atr );
    $self->{atr_panel}->render_last_visible_value( $self->{canvas_atr} );
    $self->{atr_panel}->_init_crosshair;

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

    # =========================================================================
    # hit_test: 'price'|'price_scale'|'atr'|'atr_scale'|undef
    # =========================================================================
    my $hit_test = sub {
        my ( $abs_x, $abs_y ) = @_;

        my $cpx = $cp->rootx; my $cpy = $cp->rooty;
        my $cpw = $cp->width; my $cph = $cp->height;
        if (   $abs_x >= $cpx && $abs_x < $cpx + $cpw
            && $abs_y >= $cpy && $abs_y < $cpy + $cph )
        {
            my $lx = $abs_x - $cpx;
            my $ly = $abs_y - $cpy;
            return ( $lx >= $cpw - PRICE_SCALE_W )
                ? ( 'price_scale', $lx, $ly )
                : ( 'price',       $lx, $ly );
        }

        my $cax = $ca->rootx; my $cay = $ca->rooty;
        my $caw = $ca->width; my $cah = $ca->height;
        if (   $abs_x >= $cax && $abs_x < $cax + $caw
            && $abs_y >= $cay && $abs_y < $cay + $cah )
        {
            my $lx = $abs_x - $cax;
            my $ly = $abs_y - $cay;
            return ( $lx >= $caw - PRICE_SCALE_W )
                ? ( 'atr_scale', $lx, $ly )
                : ( 'atr',       $lx, $ly );
        }

        return ( undef, 0, 0 );
    };

    # =========================================================================
    # CTRL press/release
    # =========================================================================
    for my $key (qw(Control_L Control_R)) {
        $toplevel->bind( "<KeyPress-$key>", sub {
            return if $self->{_ctrl_pressed};
            $self->{_ctrl_pressed} = 1;
            return unless $self->{_scale_price} && $self->{_mouse_x} >= 0;
            # Indice FRACCIONARIO: conserva la posicion exacta del cursor para
            # que la vela anclada no "baile" al hacer zoom con Ctrl+rueda.
            my $idx = $self->{_scale_price}->x_to_index_float( $self->{_mouse_x} );
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
    # =========================================================================
    $toplevel->bind( '<Button-4>', sub {
        my $state = $_[0]->XEvent->s;
        my $ctrl  = ( $state & 4 ) ? 1 : 0;
        my $shift = ( $state & 1 ) ? 1 : 0;

        if ($shift) {
            $self->_vertical_zoom_price(0.9) if $self->{_mouse_in_price};
            $self->_vertical_zoom_atr(0.9)   if $self->{_mouse_in_atr};
        } else {
            if ( $ctrl && !defined $self->{_zoom_anchor_idx}
                && $self->{_scale_price} && $self->{_mouse_x} >= 0 )
            {
                my $idx = $self->{_scale_price}->x_to_index_float( $self->{_mouse_x} );
                $self->{_ctrl_pressed}    = 1;
                $self->{_zoom_anchor_idx} = $idx;
                $self->{_zoom_anchor_px}  = $self->{_mouse_x};
            }
            $self->_horizontal_zoom( -1, $ctrl );
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
            if ( $ctrl && !defined $self->{_zoom_anchor_idx}
                && $self->{_scale_price} && $self->{_mouse_x} >= 0 )
            {
                my $idx = $self->{_scale_price}->x_to_index_float( $self->{_mouse_x} );
                $self->{_ctrl_pressed}    = 1;
                $self->{_zoom_anchor_idx} = $idx;
                $self->{_zoom_anchor_px}  = $self->{_mouse_x};
            }
            $self->_horizontal_zoom( 1, $ctrl );
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
        } elsif ( $panel eq 'atr' || $panel eq 'atr_scale' ) {
            $self->{_mouse_in_atr}   = 1;
            $self->{_mouse_in_price} = 0;
            $self->{_mouse_x}        = $lx;
            $self->{_mouse_y_atr}    = $ly;
        }
        $self->_request_crosshair_draw;
    });

    # =========================================================================
    # BUTTONPRESS-1
    # =========================================================================
    $toplevel->bind( '<ButtonPress-1>', sub {
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );

        # --- Modo seleccion de vela (Replay): el clic elige la vela y NO
        #     arrastra el grafico. Fuera del area de velas no inicia. ---
        if ( $self->{_pick_mode} ) {
            if ( defined $panel && $panel eq 'price' && $self->{_scale_price} ) {
                my $idx = $self->{_scale_price}->x_to_index($lx);
                my $c   = $self->{market}->get_candle($idx);
                if ($c) {
                    my $cb = $self->{_pick_cb};
                    $self->cancel_candle_pick;
                    $cb->( $idx, $c ) if $cb;
                }
            }
            return;   # traga el clic mientras se selecciona
        }

        return unless defined $panel;

        # --- Drag en regleta Y de precios: activa modo manual precio ---
        if ( $panel eq 'price_scale' ) {
            unless ( $self->{y_range_price} ) {
                my ( $s, $e ) = $self->compute_window;
                my ( $mn, $mx ) = $self->{price_panel}
                    ->get_y_range( $self->{market}->get_slice( $s, $e ) );
                $self->{y_range_price} = [ $mn, $mx ];
            }
            $self->{zoom_y_auto}        = 0;
            $self->{_scale_drag_panel}  = 'price';
            $self->{_scale_drag_start_y} = $ly;
            # Rango base al iniciar el drag: el zoom de la regleta se calcula
            # como delta ABSOLUTO desde aqui y se cuantiza a pasos de 0.25.
            ( $self->{_scale_drag_base_mn}, $self->{_scale_drag_base_mx} )
                = @{ $self->{y_range_price} };
            # Activar modo manual si no estaba ya activo
            if ( !$self->{_free_mode_price} ) {
                $self->{_free_mode_price} = 1;
                $self->_notify_mode_price(1);
            }
            return;
        }

        # --- Drag en regleta Y del ATR: activa modo manual ATR ---
        if ( $panel eq 'atr_scale' ) {
            unless ( $self->{y_range_atr} ) {
                my ( $s, $e ) = $self->compute_window;
                my ( $mn, $mx ) = $self->{atr_panel}->get_y_range(
                    $self->{indicators}->slice_array( 'atr', $s, $e ) );
                $self->{y_range_atr} = [ $mn, $mx ];
            }
            $self->{zoom_y_auto_atr}     = 0;
            $self->{_scale_drag_panel}   = 'atr';
            $self->{_scale_drag_start_y} = $ly;
            # Activar modo manual si no estaba ya activo
            if ( !$self->{_free_mode_atr} ) {
                $self->{_free_mode_atr} = 1;
                $self->_notify_mode_atr(1);
            }
            return;
        }

        # --- Drag normal en el plot ---
        $self->{_mouse_in_price} = ( $panel eq 'price' ) ? 1 : 0;
        $self->{_mouse_in_atr}   = ( $panel eq 'atr'   ) ? 1 : 0;
        $self->{_drag_start_x}   = $lx;
        $self->{_drag_start_y}   = $ly;
        $self->{_drag_offset}    = $self->{offset};
        $self->{_drag_moved}     = 0;
        $self->{_drag_panel}     = $panel;

        if ( $self->{_free_mode_price} && $panel eq 'price'
            && !$self->{y_range_price} && $self->{_scale_price} )
        {
            my ( $s, $e ) = $self->compute_window;
            my ( $mn, $mx ) = $self->{price_panel}
                ->get_y_range( $self->{market}->get_slice( $s, $e ) );
            $self->{y_range_price} = [ $mn, $mx ];
            $self->{zoom_y_auto}   = 0;
        }

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

    # =========================================================================
    # B1-MOTION
    # =========================================================================
    $toplevel->bind( '<B1-Motion>', sub {
        my $ev = $_[0]->XEvent;

        # --- Drag activo en regleta Y ---
        if ( defined $self->{_scale_drag_panel} ) {
            my $drag_panel = $self->{_scale_drag_panel};
            my $cv  = ( $drag_panel eq 'price' ) ? $cp : $ca;
            my $ly  = $ev->Y - $cv->rooty;

            # =================================================================
            # Regleta de PRECIO: zoom cuantizado en pasos de 0.25 (tick real).
            # Se usa un delta ABSOLUTO desde el inicio del drag (no incremental)
            # para que el avance sea progresivo y sin saltos: cada ~10px de
            # arrastre = un tick (0.25) por borde, y el semirango resultante se
            # redondea al multiplo de 0.25 mas cercano.
            # =================================================================
            if ( $drag_panel eq 'price'
                && defined $self->{_scale_drag_base_mn} )
            {
                my $base_mn = $self->{_scale_drag_base_mn};
                my $base_mx = $self->{_scale_drag_base_mx};
                my $mid       = ( $base_mn + $base_mx ) / 2;
                my $base_half = ( $base_mx - $base_mn ) / 2;

                my $total_dy = $ly - ( $self->{_scale_drag_start_y} // $ly );
                # Arrastrar hacia abajo (dy>0) expande el rango (aleja el zoom).
                my $ticks    = int( $total_dy / 10 );
                my $new_half = $base_half + $ticks * PRICE_TICK;

                # Cuantizar el semirango a multiplos exactos de 0.25.
                $new_half = int( $new_half / PRICE_TICK + 0.5 ) * PRICE_TICK;
                $new_half = PRICE_TICK if $new_half < PRICE_TICK;

                my ( $new_mn, $new_mx ) =
                    $self->_clamp_price_range( $mid - $new_half, $mid + $new_half );

                # Alinear ambos bordes a la grilla de 0.25.
                $new_mn = floor( $new_mn / PRICE_TICK + 0.5 ) * PRICE_TICK;
                $new_mx = floor( $new_mx / PRICE_TICK + 0.5 ) * PRICE_TICK;
                $new_mx = $new_mn + PRICE_TICK if $new_mx <= $new_mn;

                $self->{y_range_price} = [ $new_mn, $new_mx ];
                $self->request_render;
                return;
            }

            my $dy  = $ly - ( $self->{_scale_drag_start_y} // $ly );
            $self->{_scale_drag_start_y} = $ly;

            my $factor = 1.0 + $dy * 0.01;
            $factor = 0.02 if $factor < 0.02;
            $factor = 10.0 if $factor > 10.0;

            if ( $drag_panel eq 'atr' && $self->{y_range_atr} ) {
                my ( $mn, $mx ) = @{ $self->{y_range_atr} };
                my $mid  = ( $mn + $mx ) / 2;
                my $half = ( $mx - $mn ) / 2 * $factor;
                my ( $new_mn, $new_mx ) =
                    $self->_clamp_atr_range( $mid - $half, $mid + $half );
                $self->{y_range_atr} = [ $new_mn, $new_mx ];
                $self->request_render;
            }
            return;
        }

        # --- Drag normal en el plot ---
        return unless $self->{_mouse_in_price} || $self->{_mouse_in_atr};

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

        my $scale = $self->{_scale_price} // $self->{_scale_atr};
        if ( $scale && $self->{visible_bars} > 0 ) {
            my $bar_w = $scale->_plot_w / $self->{visible_bars};
            if ( $bar_w > 0 ) {
                # Pan fraccionario: desplazamiento suave coherente con el
                # offset fraccionario del zoom anclado.
                $self->{offset} =
                    ( $self->{_drag_offset} // 0 ) - ( $dx / $bar_w );
            }
        }

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

        if ( $self->{_free_mode_atr} && $self->{_mouse_in_atr}
            && $self->{y_range_atr} && abs($dy) > 0 )
        {
            my ( $mn, $mx ) = @{ $self->{y_range_atr} };
            my $plot_h = $self->{canvas_atr_h} - 14 - 6;
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
    # BUTTONRELEASE-1
    # =========================================================================
    $toplevel->bind( '<ButtonRelease-1>', sub {
        if ( defined $self->{_scale_drag_panel} ) {
            $self->{_scale_drag_panel}    = undef;
            $self->{_scale_drag_start_y}  = undef;
            $self->{_scale_drag_base_mn}  = undef;
            $self->{_scale_drag_base_mx}  = undef;
            return;
        }

        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;
        return if $panel eq 'price_scale' || $panel eq 'atr_scale';

        my $dx = $lx - ( $self->{_drag_start_x} // $lx );
        my $dy = $ly - ( $self->{_drag_start_y} // $ly );

        return if $self->{_free_mode_price} && $panel eq 'price';
        return if $self->{_free_mode_atr}   && $panel eq 'atr';
        return if abs($dx) > DRAG_THRESHOLD || abs($dy) > DRAG_THRESHOLD;

    });

    # =========================================================================
    # DOBLE CLICK IZQUIERDO
    # Regleta Y -> restaurar autozoom + volver a modo Auto
    # Plot      -> borrar marca persistente
    # =========================================================================
    $toplevel->bind( '<Double-Button-1>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;

        if ( $panel eq 'price_scale' ) {
            $self->{zoom_y_auto}      = 1;
            $self->{y_range_price}    = undef;
            $self->{_free_mode_price} = 0;
            $self->_notify_mode_price(0);
            $self->request_render;
            return;
        }
        if ( $panel eq 'atr_scale' ) {
            $self->{zoom_y_auto_atr} = 1;
            $self->{y_range_atr}     = undef;
            $self->{_free_mode_atr}  = 0;
            $self->_notify_mode_atr(0);
            $self->request_render;
            return;
        }
        if ( $panel eq 'price' ) {
            $self->{_price_cross} = undef;
            $self->{canvas_price}->delete('price_cross');
        } elsif ( $panel eq 'atr' ) {
            $self->{_atr_cross} = undef;
            $self->{canvas_atr}->delete('atr_cross');
        }
    });

    # =========================================================================
    # ESC: borra AMBAS marcas persistentes
    # =========================================================================
    $toplevel->bind( '<Escape>', sub {
        # Escape tambien aborta la seleccion de vela del Replay, si esta activa.
        if ( $self->{_pick_mode} ) {
            my $cb = $self->{_pick_cb};
            $self->cancel_candle_pick;
            $cb->( undef, undef ) if $cb;   # avisa a la UI que se cancelo
        }
        $self->{_price_cross} = undef;
        $self->{_atr_cross}   = undef;
        $self->{canvas_price}->delete('price_cross');
        $self->{canvas_atr}->delete('atr_cross');
    });

    # =========================================================================
    # DRAG DERECHO: zoom/pan vertical en el plot
    # =========================================================================
    $toplevel->bind( '<ButtonPress-3>', sub {
        my $ev = $_[0]->XEvent;
        my ( $panel, $lx, $ly ) = $hit_test->( $ev->X, $ev->Y );
        return unless defined $panel;
        return if $panel eq 'price_scale' || $panel eq 'atr_scale';

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

        if ( !defined $panel || $panel eq 'price_scale' || $panel eq 'atr_scale' ) {
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
        if ( $panel eq 'price' || $panel eq 'price_scale' ) {
            $self->{zoom_y_auto}   = 1;
            $self->{y_range_price} = undef;
        } else {
            $self->{zoom_y_auto_atr} = 1;
            $self->{y_range_atr}     = undef;
        }
        $self->request_render;
    });

    # =========================================================================
    # RESIZE — ignorar si estamos en resize manual del separador
    # =========================================================================
    $toplevel->bind( '<Configure>', sub {
        return if $self->{_resizing_panels};

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
# FIX: Agregada validacion para romper el bucle infinito cuando el redondeo
# de enteros atasca el factor de escala al llegar a MIN_BARS o al alejar.
# -----------------------------------------------------------------------------
sub _horizontal_zoom {
    my ( $self, $dir, $use_anchor ) = @_;
    my $old = $self->{visible_bars};
    
    my $new;
    if ( $dir > 0 ) {
        $new = int( $old * 1.15 );
        $new++ if $new == $old; # Fuerza el salto si el redondeo lo estanca
    } else {
        $new = int( $old / 1.15 );
        $new-- if $new == $old; # Fuerza el salto si el redondeo lo estanca
    }

    $new = MIN_BARS if $new < MIN_BARS;
    $new = MAX_BARS if $new > MAX_BARS;
    return if $new == $old;

    if ( $use_anchor && defined $self->{_zoom_anchor_idx} && $self->{_scale_price} ) {
        # Anclaje FRACCIONARIO: el offset se calcula sin truncar a entero, de
        # modo que la coordenada de dato bajo el cursor (anchor_idx) siga
        # cayendo EXACTAMENTE en el mismo pixel (anchor_px) tras el zoom. Esto
        # elimina el "baile" de la grafica con Ctrl+rueda.
        my $anchor_idx = $self->{_zoom_anchor_idx};
        my $anchor_px  = $self->{_zoom_anchor_px};
        my $bar_w_new  = $self->{_scale_price}->_plot_w / $new;
        $self->{visible_bars} = $new;
        $self->{offset} = $anchor_idx - ( $anchor_px / $bar_w_new );
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
    my $factor = 1.0 - ( $dy / $plot_h );
    $factor = 0.05 if $factor < 0.05;
    $factor = 5.0  if $factor > 5.0;
    my $mid  = ( $mn + $mx ) / 2;
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
    my $factor = 1.0 - ( $dy / $plot_h );
    $factor = 0.05 if $factor < 0.05;
    $factor = 5.0  if $factor > 5.0;
    my $mid  = ( $mn + $mx ) / 2;
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
# -----------------------------------------------------------------------------
sub _draw_crosshair_all {
    my ($self) = @_;

    my $x;
    if ( $self->{_ctrl_pressed} && defined $self->{_zoom_anchor_px} ) {
        $x = $self->{_zoom_anchor_px};
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
            my $snap_x   = ( $self->{_free_mode_price} || $self->{_ctrl_pressed} )
                ? $x
                : $self->{_scale_price}->index_to_center_x($snap_idx);
            $self->{price_panel}->draw_crosshair( $snap_x, $y, $candle_info );
        } elsif ( $self->{_mouse_in_atr} ) {
            my $snap_idx = $self->{_scale_price}->x_to_index($x);
            my $snap_x   = $self->{_scale_price}->index_to_center_x($snap_idx);
            $self->{price_panel}->show_vline_only($snap_x);
            
            if ($candle_info) {
                $self->{price_panel}->show_ohlcv_info($candle_info);
                $self->{price_panel}->draw_time_label($snap_x, $candle_info);
            }
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

    # El indice del marcador de inicio es relativo a la TF anterior: invalidarlo.
    $self->{_replay_start_index} = undef;
    $self->{_replay_start_label} = undef;
    $self->{canvas_price}->delete('replay_marker');

    $self->{_free_mode_price} = 0;
    $self->{_free_mode_atr}   = 0;
    $self->{zoom_y_auto}      = 1;
    $self->{y_range_price}    = undef;
    $self->{zoom_y_auto_atr}  = 1;
    $self->{y_range_atr}      = undef;

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

# -----------------------------------------------------------------------------
# follow_replay_pointer (Etapa 3, Fase 2)
# Reposiciona la ventana visible para que la ultima vela del puntero de
# Replay quede a la vista, SIN tocar visible_bars ni el estado de zoom
# vertical -- a diferencia de reset_view, que reinicia todo. Se llama
# desde el callback on_change de Market::Replay cada vez que el puntero
# avanza/retrocede/arranca/sale, para que el usuario nunca pierda de
# vista la vela que el replay esta mostrando, conservando el zoom que
# tenia elegido.
# -----------------------------------------------------------------------------
sub follow_replay_pointer {
    my ($self) = @_;
    my $total = $self->{market}->size;
    return if $total <= 0;

    my $ptr        = $total - 1;                       # ultima vela del replay
    my $bars       = $self->{visible_bars};
    my $right_edge = $self->{offset} + $bars - 1;

    # Politica de encuadre tipo TradingView:
    #  - Al ARRANCAR (o retroceder), el puntero cae a la IZQUIERDA de la ventana
    #    actual -> se reencuadra con el puntero al borde izquierdo y espacio
    #    vacio a la derecha que se ira llenando al avanzar (spec 18).
    #  - Mientras el puntero avanza DENTRO de la ventana, el offset NO se toca
    #    (la vela seleccionada se mantiene a la izquierda y el grafico se llena
    #    hacia la derecha).
    #  - Cuando el puntero se sale por la DERECHA, recien ahi se hace scroll
    #    para mantenerlo a la vista.
    if ( $ptr < $self->{offset} ) {
        $self->{offset} = $ptr;                        # puntero al borde izquierdo
    }
    elsif ( $ptr > $right_edge ) {
        $self->{offset} = $ptr - ( $bars - 1 );        # puntero al borde derecho
    }
    # else: dentro de la ventana -> no mover (se llena hacia la derecha).

    $self->request_render;
}

sub compute_intraday_labels {
    my ( $self, $start, $end ) = @_;

    my $visible = $end - $start + 1;
    return [] if $visible <= 0;

    my %tf_min   = (
        '1m' => 1,    '5m' => 5,    '15m' => 15,
        '1h' => 60,   '2h' => 120,  '4h'  => 240,
        'D'  => 1440, 'W'  => 10080,
    );
    my $tf       = $self->{market}->get_timeframe;
    my $bar_min  = $tf_min{$tf} // 1;

    # FIX (Etapa 1, Fase 2): se extiende la lista de pasos "bonitos" mas
    # alla de 1440 (1 dia) para que D y W tambien encuentren un paso de
    # etiquetado razonable en vez de quedarse atascados en el ultimo
    # valor por defecto.
    my @nice     = ( 1, 2, 5, 10, 15, 20, 30, 60, 120, 240, 360, 720,
                      1440, 2880, 5760, 10080, 20160, 43200 );
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
            my $wday = ( gmtime( $c->{ts} - 5*3600 ) )[6];
            $label = $DAY_ABBR[$wday] . ' ' . $mday;
        } else {
            $label = sprintf( '%d:%02d',
                int( $cur_slot * $step_min / 60 ),
                ( $cur_slot * $step_min ) % 60 );
        }

        push @result, { index => $i, label => $label, ts => $c->{ts} };
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