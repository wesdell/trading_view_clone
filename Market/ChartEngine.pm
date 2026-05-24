package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine
# Orquestador del sistema de visualizacion: une datos, indicadores, paneles
# y eventos del usuario. Punto de ensamblaje del sistema visual.
#
# Responsabilidades:
#   - compute_window: calcula el rango visible (offset, visible_bars).
#   - render: dibuja todos los paneles sincronizados.
#   - bind_events: maneja drag, zoom, click, crosshair.
#   - Mantiene el estado del marcador de precio/ATR en regletas.
#
# Sincronizacion entre paneles:
#   - Eje X comun: linea vertical del crosshair en AMBOS paneles.
#   - Eje Y independiente: linea horizontal + caja de valor solo en el panel
#     donde esta el cursor.
#   - OHLCV label en el panel de precios se actualiza cuando el cursor esta
#     en cualquiera de los dos paneles.
#
# Optimizacion para rendimiento:
#   - El crosshair se crea UNA SOLA VEZ y se mueve con coords() en cada
#     evento de mouse  ->  acceso O(1).
#   - Los marcadores persistentes (click en regleta) se borran y redibujan
#     solo cuando hay cambio real.
#   - El drag horizontal se "throttlea" via request_render (after diferido).
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
    DRAG_THRESHOLD => 3,    # pixeles minimos para considerar drag (no click)
    # Limites del zoom vertical (multiplos del rango de datos)
    Y_ZOOM_MIN     => 0.10, # max zoom-in: rango no puede ser < 10% del rango de datos
    Y_ZOOM_MAX     => 3.00, # max zoom-out: rango no puede ser > 3x el rango de datos
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
        # Estado de la ventana visible
        visible_bars    => DEFAULT_BARS,
        offset          => 0,
        # Zoom Y precios
        zoom_y_auto     => 1,
        y_range_price   => undef,
        # Zoom Y ATR
        zoom_y_auto_atr => 1,
        y_range_atr     => undef,
        # Render diferido
        _render_pending => 0,
        # Drag horizontal (mouse izquierdo)
        _drag_start_x   => undef,
        _drag_start_y   => undef,
        _drag_offset    => undef,
        _drag_moved     => 0,
        # Drag vertical (mouse derecho)
        _drag_y_start     => undef,
        _drag_y_start_atr => undef,
        # Mouse actual (para crosshair)
        _mouse_x        => -1,
        _mouse_y        => -1,
        _mouse_y_atr    => -1,
        _mouse_in_price => 0,
        _mouse_in_atr   => 0,
        # Scales actuales (referencia mutable para mouse handlers)
        _scale_price    => undef,
        _scale_atr      => undef,
        # Cruces persistentes (click): guardamos coordenadas logicas
        # ({ idx => indice de la vela, value => precio/ATR }) por panel.
        # Se redibujan tras cada render para que sobrevivan zoom/scroll.
        _price_cross => undef,   # { idx => N, value => precio }
        _atr_cross   => undef,   # { idx => N, value => atr }
    };
    bless $self, $class;
    $self->bind_events;
    return $self;
}

# -----------------------------------------------------------------------------
# compute_window
# Calcula (start, end) del slice visible. Clampea offset a [0, total-1].
# Garantiza que SIEMPRE haya al menos una vela visible (evita pantalla
# en blanco al hacer scroll mas alla del final).
# -----------------------------------------------------------------------------
sub compute_window {
    my ($self) = @_;
    my $total = $self->{market}->size;
    return (0, 0) unless $total > 0;

    my $bars = $self->{visible_bars};

    # Offset minimo: 0 (no podemos ir antes del primer dato)
    # Offset maximo: total-1 (al menos la ultima vela visible)
    # Si el offset cae mas alla del final, lo movemos a (total - bars)
    # para que se vea contenido en lugar de pantalla en blanco.
    my $max_offset = $total - $bars;
    $max_offset    = 0 if $max_offset < 0;

    $self->{offset} = $max_offset if $self->{offset} > $max_offset;
    $self->{offset} = 0           if $self->{offset} < 0;

    my $start = $self->{offset};
    my $end   = $start + $bars - 1;
    $end      = $total - 1 if $end >= $total;
    return ($start, $end);
}

sub round {
    my ($self, $value, $dec) = @_;
    $dec //= 2;
    return sprintf("%.${dec}f", $value) + 0;
}

# -----------------------------------------------------------------------------
# request_render
# Render diferido: agrupa eventos rapidos (zoom + drag + motion) en un solo
# render. Tk dispatcha el callback when idle = render mas fluido.
# -----------------------------------------------------------------------------
sub request_render {
    my ($self) = @_;

    return
      if $self->{_render_pending};

    $self->{_render_pending} = 1;
    $self->{canvas_price}->after(1, sub {
        $self->{_render_pending} = 0;
        $self->render;
    });
}

# -----------------------------------------------------------------------------
# _request_crosshair_draw
# Throttle del crosshair: si llegan muchos eventos <Motion> en rafaga,
# los agrupamos en una sola pasada de redibujado, lo que da una sensacion
# mucho mas fluida y reduce parpadeo en X11/XWayland.
# -----------------------------------------------------------------------------
sub _request_crosshair_draw {
    my ($self) = @_;
    return if $self->{_crosshair_pending};
    $self->{_crosshair_pending} = 1;
    $self->{canvas_price}->after(1, sub {
        $self->{_crosshair_pending} = 0;
        $self->_draw_crosshair_all;
    });
}

# -----------------------------------------------------------------------------
# render
# Render principal: calcula slice visible, ranges, escalas, y dibuja
# ambos paneles. Finalmente actualiza crosshair y marcadores.
# -----------------------------------------------------------------------------
sub render {
    my ($self) = @_;

    return if $self->{market}->size == 0;
    my ($start, $end) = $self->compute_window;

    # Estas dimensiones son actualizadas por el handler <Configure>
    # (al final de bind_events) cada vez que la ventana se redimensiona.
    my $canv_w  = $self->{canvas_w};
    my $canv_ph = $self->{canvas_price_h};
    my $canv_ah = $self->{canvas_atr_h};

    # Slice de datos visibles
    my $visible_candles = $self->{market}->get_slice($start, $end);
    my $visible_atr     = $self->{indicators}->slice_array('atr', $start, $end);

    my $real_bars = scalar @$visible_candles;
    $real_bars    = 1 if $real_bars < 1;

    # --- Rango Y precios ---
    my ($min_p, $max_p);
    if ($self->{zoom_y_auto}) {
        ($min_p, $max_p) = $self->{price_panel}->get_y_range($visible_candles);
    } else {
        ($min_p, $max_p) = @{ $self->{y_range_price} };
    }
    my $last_visible = $visible_candles->[-1];

    # --- Scale precios ---
    my $scale_price = Market::Panels::Scales->new(
        canvas_w      => $canv_w,
        canvas_h      => $canv_ph,
        price_scale_w => PRICE_SCALE_W,
        visible_bars  => $real_bars,
        offset        => $start,
        min_val       => $min_p,
        max_val       => $max_p,
        padding_top   => 10,
        padding_bot   => TIME_AXIS_H,
        last_close    => $last_visible ? $last_visible->{close} : undef,
    );
    $self->{price_panel}->set_scale($scale_price);
    $self->{_scale_price} = $scale_price;

    # --- Rango Y ATR ---
    my ($min_a, $max_a);
    if ($self->{zoom_y_auto_atr}) {
        ($min_a, $max_a) = $self->{atr_panel}->get_y_range($visible_atr);
    } else {
        ($min_a, $max_a) = @{ $self->{y_range_atr} };
    }
    my $last_atr_val;
    for my $v (reverse @$visible_atr) {
        if (defined $v) { $last_atr_val = $v; last; }
    }

    # --- Scale ATR ---
    # visible_atr es slice relativo (i=0 = primera barra visible)
    # offset=0, visible_bars=real_bars -> mismo ancho de barra que precios.
    my $scale_atr = Market::Panels::Scales->new(
        canvas_w      => $canv_w,
        canvas_h      => $canv_ah,
        price_scale_w => PRICE_SCALE_W,
        visible_bars  => $real_bars,
        offset        => 0,
        min_val       => $min_a,
        max_val       => $max_a,
        padding_top   => 14,
        padding_bot   => 6,
        last_atr_val  => $last_atr_val,
    );
    $self->{atr_panel}->set_scale($scale_atr);
    $self->{_scale_atr} = $scale_atr;

    # --- Render panel precios ---
    $self->{canvas_price}->delete('price_bg');
    $self->{canvas_price}->delete('candle');
    $self->{canvas_price}->delete('scale_bg');
    $self->{canvas_price}->delete('scale_border');
    $self->{canvas_price}->delete('scale_grid');
    $self->{canvas_price}->delete('scale_label');
    $self->{canvas_price}->delete('last_price');
    $self->{canvas_price}->delete('time_axis');

    $self->{price_panel}->render($self->{canvas_price}, $visible_candles, $scale_price);

    my $anchors = $self->compute_intraday_labels($start, $end);
    $self->{price_panel}->draw_time_axis($self->{canvas_price}, $anchors);

    # Crosshair y cruz persistente del panel de precios
    $self->{price_panel}->_init_crosshair_objects;
    $self->_draw_price_cross;

    # --- Render panel ATR ---
    $self->{canvas_atr}->delete('atr_all');
    $self->{canvas_atr}->delete('scale_bg');
    $self->{canvas_atr}->delete('scale_border');
    $self->{canvas_atr}->delete('scale_grid');
    $self->{canvas_atr}->delete('scale_label');

    $self->{atr_panel}->render($self->{canvas_atr}, $visible_atr, $scale_atr);
    $self->{atr_panel}->_init_crosshair;
    $self->_draw_atr_cross;

    # Reposicionar crosshair en su ultima ubicacion (si el mouse esta dentro)
    $self->_draw_crosshair_all;
}

# -----------------------------------------------------------------------------
# bind_events
# Registra todos los eventos de mouse y teclado.
#
# Comportamiento:
#   Rueda             -> zoom horizontal
#   Ctrl + Rueda      -> zoom vertical del panel bajo el mouse
#   Drag izq          -> scroll horizontal del grafico
#   Click simple izq  -> marca precio/ATR en la regleta del panel clickeado
#   Doble click izq   -> elimina marcador de regleta
#   Drag der          -> zoom vertical manual del panel bajo el mouse
#   Doble click der   -> vuelve a zoom Y automatico
#   Motion            -> mueve crosshair sincronizado
# -----------------------------------------------------------------------------
sub bind_events {
    my ($self) = @_;

    my $cp = $self->{canvas_price};
    my $ca = $self->{canvas_atr};

    $cp->configure(-takefocus => 1);
    $ca->configure(-takefocus => 1);

    my $toplevel = $cp->toplevel;

    # =========================================================================
    # HELPER hit_test
    #
    # Recibe coordenadas ABSOLUTAS del root window ($ev->X / $ev->Y con
    # mayuscula, no minuscula) y devuelve qué panel esta bajo el mouse +
    # las coordenadas LOCALES del canvas correspondiente.
    #
    # Usamos coords del root porque son las unicas que son fiables al
    # bindear en el toplevel: $ev->x/y con minuscula vienen relativas al
    # widget que ORIGINALMENTE recibio el evento (que puede ser el canvas,
    # el frame de la toolbar, el toplevel...), mientras que $ev->X/Y con
    # mayuscula SIEMPRE son absolutas. Convertimos con $canvas->rootx/rooty
    # para obtener el origen del canvas en root, restamos y listo.
    # =========================================================================
    my $hit_test = sub {
        my ($abs_x, $abs_y) = @_;

        my $cpx = $cp->rootx; my $cpy = $cp->rooty;
        my $cpw = $cp->width; my $cph = $cp->height;
        if ($abs_x >= $cpx && $abs_x < $cpx + $cpw
        &&  $abs_y >= $cpy && $abs_y < $cpy + $cph) {
            return ('price', $abs_x - $cpx, $abs_y - $cpy);
        }

        my $cax = $ca->rootx; my $cay = $ca->rooty;
        my $caw = $ca->width; my $cah = $ca->height;
        if ($abs_x >= $cax && $abs_x < $cax + $caw
        &&  $abs_y >= $cay && $abs_y < $cay + $cah) {
            return ('atr', $abs_x - $cax, $abs_y - $cay);
        }

        return (undef, 0, 0);
    };

    # =========================================================================
    # RUEDA: zoom horizontal / vertical (Ctrl + rueda = zoom V)
    # =========================================================================
    $toplevel->bind('<Button-4>', sub {
        my $state = $_[0]->XEvent->s;
        if ($state & 4) {
            $self->_vertical_zoom_price(0.9) if $self->{_mouse_in_price};
            $self->_vertical_zoom_atr(0.9)   if $self->{_mouse_in_atr};
        } else {
            $self->_horizontal_zoom(-1);
        }
        Tk->break;
    });
    $toplevel->bind('<Button-5>', sub {
        my $state = $_[0]->XEvent->s;
        if ($state & 4) {
            $self->_vertical_zoom_price(1.1) if $self->{_mouse_in_price};
            $self->_vertical_zoom_atr(1.1)   if $self->{_mouse_in_atr};
        } else {
            $self->_horizontal_zoom(1);
        }
        Tk->break;
    });

    # =========================================================================
    # MOTION: crosshair sincronizado + deteccion de panel activo
    # =========================================================================
    $toplevel->bind('<Motion>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel, $lx, $ly) = $hit_test->($ev->X, $ev->Y);

        unless (defined $panel) {
            if ($self->{_mouse_in_price} || $self->{_mouse_in_atr}) {
                $self->{_mouse_in_price} = 0;
                $self->{_mouse_in_atr}   = 0;
                $self->{price_panel}->hide_crosshair;
                $self->{atr_panel}->hide_crosshair;
            }
            return;
        }

        if ($panel eq 'price') {
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
    # DRAG IZQUIERDO: scroll horizontal
    # =========================================================================
    $toplevel->bind('<ButtonPress-1>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel, $lx, $ly) = $hit_test->($ev->X, $ev->Y);
        return unless defined $panel;

        if ($panel eq 'price') {
            $self->{_mouse_in_price} = 1;
            $self->{_mouse_in_atr}   = 0;
        } else {
            $self->{_mouse_in_atr}   = 1;
            $self->{_mouse_in_price} = 0;
        }
        $self->{_drag_start_x} = $lx;
        $self->{_drag_start_y} = $ly;
        $self->{_drag_offset}  = $self->{offset};
        $self->{_drag_moved}   = 0;
        $self->{_drag_panel}   = $panel;
    });

    $toplevel->bind('<B1-Motion>', sub {
        return unless $self->{_mouse_in_price} || $self->{_mouse_in_atr};
        my $ev = $_[0]->XEvent;
        my ($panel, $lx, $ly) = $hit_test->($ev->X, $ev->Y);

        # Si el mouse salio de cualquier panel durante el drag,
        # convertimos manualmente usando el canvas del panel original.
        if (!defined $panel) {
            my $cv = ($self->{_drag_panel} || 'price') eq 'price' ? $cp : $ca;
            $lx = $ev->X - $cv->rootx;
            $ly = $ev->Y - $cv->rooty;
        }

        my $dx = $lx - ($self->{_drag_start_x} // $lx);
        my $dy = $ly - ($self->{_drag_start_y} // $ly);

        $self->{_drag_moved} = 1
            if abs($dx) > DRAG_THRESHOLD || abs($dy) > DRAG_THRESHOLD;
        return unless $self->{_drag_moved};

        my $scale = $self->{_scale_price} // $self->{_scale_atr};
        if ($scale && $self->{visible_bars} > 0) {
            my $bar_w = $scale->_plot_w / $self->{visible_bars};
            if ($bar_w > 0) {
                $self->{offset} = ($self->{_drag_offset} // 0)
                                - int($dx / $bar_w);
            }
        }
        $self->{_mouse_x} = $lx;
        $self->request_render;
    });

    $toplevel->bind('<ButtonRelease-1>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel, $lx, $ly) = $hit_test->($ev->X, $ev->Y);
        return unless defined $panel;

        my $dx = $lx - ($self->{_drag_start_x} // $lx);
        my $dy = $ly - ($self->{_drag_start_y} // $ly);
        return if abs($dx) > DRAG_THRESHOLD
               || abs($dy) > DRAG_THRESHOLD;

        if ($panel eq 'price' && $self->{_scale_price}) {
            my $scale = $self->{_scale_price};
            return if $lx > $scale->_plot_w;
            return if $ly > $scale->{canvas_h} - $scale->{padding_bot};
            $self->{_price_cross} = {
                idx   => $scale->x_to_index($lx),
                value => $scale->y_to_value($ly),
            };
            $self->_draw_price_cross;
        }
        elsif ($panel eq 'atr' && $self->{_scale_atr}) {
            my $scale = $self->{_scale_atr};
            return if $lx > $scale->_plot_w;
            $self->{_atr_cross} = {
                idx   => $scale->x_to_index($lx) + $self->{offset},
                value => $scale->y_to_value($ly),
            };
            $self->_draw_atr_cross;
        }
    });

    # =========================================================================
    # DOBLE CLICK IZQUIERDO: borrar cruz persistente
    # =========================================================================
    $toplevel->bind('<Double-Button-1>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel) = $hit_test->($ev->X, $ev->Y);
        return unless defined $panel;
        if ($panel eq 'price') {
            $self->{_price_cross} = undef;
            $self->{canvas_price}->delete('price_cross');
        } else {
            $self->{_atr_cross} = undef;
            $self->{canvas_atr}->delete('atr_cross');
        }
    });

    # =========================================================================
    # DRAG DERECHO: zoom vertical / pan vertical por panel
    # =========================================================================
    $toplevel->bind('<ButtonPress-3>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel, $lx, $ly) = $hit_test->($ev->X, $ev->Y);
        return unless defined $panel;

        if ($panel eq 'price') {
            $self->{_drag_y_start} = $ly;
            unless ($self->{y_range_price}) {
                my ($s, $e) = $self->compute_window;
                my ($mn, $mx) = $self->{price_panel}
                    ->get_y_range($self->{market}->get_slice($s, $e));
                $self->{y_range_price} = [$mn, $mx];
            }
            $self->{zoom_y_auto} = 0;
        } else {
            $self->{_drag_y_start_atr} = $ly;
            unless ($self->{y_range_atr}) {
                my ($s, $e) = $self->compute_window;
                my ($mn, $mx) = $self->{atr_panel}->get_y_range(
                    $self->{indicators}->slice_array('atr', $s, $e));
                $self->{y_range_atr} = [$mn, $mx];
            }
            $self->{zoom_y_auto_atr} = 0;
        }
    });

    $toplevel->bind('<B3-Motion>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel, $lx, $ly) = $hit_test->($ev->X, $ev->Y);

        # Si salio del panel durante el drag, usar coords del panel original
        if (!defined $panel) {
            my $cv = ($self->{_drag_panel} || 'price') eq 'price' ? $cp : $ca;
            $ly = $ev->Y - $cv->rooty;
            $panel = $self->{_drag_panel} || 'price';
        }

        if ($panel eq 'price') {
            my $dy = $ly - ($self->{_drag_y_start} // $ly);
            $self->{_drag_y_start} = $ly;
            $self->_vertical_drag($dy);
        } else {
            my $dy = $ly - ($self->{_drag_y_start_atr} // $ly);
            $self->{_drag_y_start_atr} = $ly;
            $self->_vertical_drag_atr($dy);
        }
    });

    $toplevel->bind('<Double-Button-3>', sub {
        my $ev = $_[0]->XEvent;
        my ($panel) = $hit_test->($ev->X, $ev->Y);
        return unless defined $panel;
        if ($panel eq 'price') {
            $self->{zoom_y_auto}   = 1;
            $self->{y_range_price} = undef;
        } else {
            $self->{zoom_y_auto_atr} = 1;
            $self->{y_range_atr}     = undef;
        }
        $self->request_render;
    });

    # =========================================================================
    # RESIZE: actualiza dimensiones y re-renderiza
    # =========================================================================
    $toplevel->bind('<Configure>', sub {
        my $new_w  = $self->{canvas_price}->width;
        my $new_h  = $self->{canvas_price}->height;
        my $new_ah = $self->{canvas_atr}->height;
        # Ignorar si no cambio nada o si los valores aun no son validos
        return if $new_w  <= 1 || $new_h <= 1;
        return if $new_w  == $self->{canvas_w}
               && $new_h  == $self->{canvas_price_h}
               && $new_ah == $self->{canvas_atr_h};
        $self->{canvas_w}       = $new_w;
        $self->{canvas_price_h} = $new_h;
        $self->{canvas_atr_h}   = $new_ah;
        $self->{canvas_price}->configure(
            -scrollregion => [0, 0, $new_w, $new_h]);
        $self->{canvas_atr}->configure(
            -scrollregion => [0, 0, $new_w, $new_ah]);
        $self->request_render;
    });
}

# -----------------------------------------------------------------------------
# _horizontal_zoom
# $dir -1 = acercar (menos velas), +1 = alejar (mas velas).
# Centra el zoom en el punto medio actual.
# -----------------------------------------------------------------------------
sub _horizontal_zoom {
    my ($self, $dir) = @_;
    my $old = $self->{visible_bars};
    my $new = ($dir > 0) ? int($old * 1.15) : int($old / 1.15);
    $new = MIN_BARS if $new < MIN_BARS;
    $new = MAX_BARS if $new > MAX_BARS;
    return if $new == $old;

    my $center = $self->{offset} + int($old / 2);
    $self->{visible_bars} = $new;
    $self->{offset}       = $center - int($new / 2);
    $self->{offset}       = 0 if $self->{offset} < 0;
    $self->request_render;
}

# -----------------------------------------------------------------------------
# _clamp_price_range
# Limita el rango Y del panel de precios para que:
#   - No sea mas estrecho que Y_ZOOM_MIN * rango_de_datos (anti zoom-in
#     infinito que amontona velas en el borde).
#   - No sea mas ancho que Y_ZOOM_MAX * rango_de_datos (anti zoom-out
#     que deja las velas como una linea fina al medio).
#   - Los datos siempre sean parcialmente visibles (anti pan extremo).
# -----------------------------------------------------------------------------
sub _clamp_price_range {
    my ($self, $new_mn, $new_mx) = @_;
    my $range = $new_mx - $new_mn;
    return ($new_mn, $new_mx) if $range <= 0;

    my ($s, $e) = $self->compute_window;
    my $vis = $self->{market}->get_slice($s, $e);
    return ($new_mn, $new_mx) unless $vis && @$vis;

    my $data_max = $vis->[0]{high};
    my $data_min = $vis->[0]{low};
    for my $c (@$vis) {
        $data_max = $c->{high} if $c->{high} > $data_max;
        $data_min = $c->{low}  if $c->{low}  < $data_min;
    }
    my $data_range = $data_max - $data_min;
    $data_range    = 1 if $data_range < 1;
    my $margin     = $data_range * 0.10;

    # Cap superior: rango maximo permitido
    my $max_range = $data_range * Y_ZOOM_MAX;
    if ($range > $max_range) {
        my $center = ($new_mn + $new_mx) / 2;
        $range  = $max_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    # Cap inferior: rango minimo permitido (evita zoom-in infinito)
    my $min_range = $data_range * Y_ZOOM_MIN;
    if ($range < $min_range) {
        my $center = ($new_mn + $new_mx) / 2;
        $range  = $min_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    # Datos siempre parcialmente visibles
    if ($new_mx < $data_min + $margin) {
        $new_mx = $data_min + $margin;
        $new_mn = $new_mx - $range;
    }
    if ($new_mn > $data_max - $margin) {
        $new_mn = $data_max - $margin;
        $new_mx = $new_mn + $range;
    }

    return ($new_mn, $new_mx);
}

# -----------------------------------------------------------------------------
# _clamp_atr_range
# Similar a _clamp_price_range pero para el ATR. ATR siempre >= 0.
# -----------------------------------------------------------------------------
sub _clamp_atr_range {
    my ($self, $new_mn, $new_mx) = @_;
    my $range = $new_mx - $new_mn;
    return ($new_mn, $new_mx) if $range <= 0;

    my ($s, $e) = $self->compute_window;
    my $vis_atr = $self->{indicators}->slice_array('atr', $s, $e);
    my @valid   = grep { defined $_ } @$vis_atr;
    return ($new_mn, $new_mx) unless @valid;

    my $data_max = $valid[0];
    for my $v (@valid) { $data_max = $v if $v > $data_max; }
    my $data_range = $data_max;
    $data_range    = 0.1 if $data_range < 0.1;
    my $margin     = $data_range * 0.5;

    # Cap superior: rango maximo permitido (3x el max de datos)
    my $max_range = $data_range * Y_ZOOM_MAX;
    if ($range > $max_range) {
        my $center = ($new_mn + $new_mx) / 2;
        $range  = $max_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    # Cap inferior: rango minimo permitido (anti zoom-in)
    my $min_range = $data_range * Y_ZOOM_MIN;
    if ($range < $min_range) {
        my $center = ($new_mn + $new_mx) / 2;
        $range  = $min_range;
        $new_mn = $center - $range / 2;
        $new_mx = $center + $range / 2;
    }

    # ATR no puede ser negativo
    if ($new_mn < 0) {
        $new_mx -= $new_mn;
        $new_mn  = 0;
    }
    # Datos parcialmente visibles
    if ($new_mx > $data_max + $margin && $range >= $max_range) {
        $new_mx = $data_max + $margin;
        $new_mn = $new_mx - $range;
        $new_mn = 0 if $new_mn < 0;
    }
    return ($new_mn, $new_mx);
}

# -----------------------------------------------------------------------------
# _draw_price_cross
# Cruz persistente (click) en el panel de precios. Sobrevive a zoom/scroll.
# -----------------------------------------------------------------------------
sub _draw_price_cross {
    my ($self) = @_;
    my $cross  = $self->{_price_cross};
    my $canvas = $self->{canvas_price};
    my $scale  = $self->{_scale_price};

    $canvas->delete('price_cross');
    return unless defined $cross && $scale;

    # Color del crosshair persistente
    my $color = '#2962ff';   # azul TradingView

    # Reconstruir (x, y) de pantalla desde el (idx, value) logico
    my $x = $scale->index_to_center_x($cross->{idx});
    my $y = $scale->value_to_y($cross->{value});

    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};
    my $y_sep = $scale->{canvas_h} - $scale->{padding_bot};

    # Si el indice quedo fuera de la ventana visible, no dibujamos
    # las lineas (pero la cruz logica se mantiene para cuando vuelva).
    my $idx_in_view =
        ($cross->{idx} >= $scale->{offset}
         && $cross->{idx} <  $scale->{offset} + $scale->{visible_bars}
         && $x >= 0 && $x <= $x_sep);

    if ($idx_in_view) {
        # Linea vertical
        $canvas->createLine($x, 0, $x, $y_sep,
            -fill => $color, -dash => [4, 3], -width => 1,
            -tags => ['price_cross']);
    }

    # Linea horizontal: si el valor esta dentro del rango visible
    if ($scale->value_in_range($cross->{value})) {
        $canvas->createLine(0, $y, $x_sep, $y,
            -fill => $color, -dash => [4, 3], -width => 1,
            -tags => ['price_cross']);

        # Caja en regleta Y con el precio
        $canvas->createRectangle($x_sep+1, $y-9, $x_end-1, $y+9,
            -fill => $color, -outline => $color,
            -tags => ['price_cross']);
        $canvas->createText($x_sep + ($x_end - $x_sep) / 2, $y,
            -text   => sprintf('%.2f', $cross->{value}),
            -fill   => '#ffffff',
            -anchor => 'center',
            -font   => 'TkFixedFont 8 bold',
            -tags   => ['price_cross']);
    }

    # Caja en regleta X (eje temporal) con la hora de la vela
    if ($idx_in_view) {
        my $candle = $self->{market}->get_candle($cross->{idx});
        if ($candle) {
            my $time_lbl = _format_time_for_axis($candle->{time});
            my $w = length($time_lbl) * 5 + 12;
            $canvas->createRectangle($x - $w/2, $y_sep + 1, $x + $w/2, $y_sep + 17,
                -fill => $color, -outline => $color,
                -tags => ['price_cross']);
            $canvas->createText($x, $y_sep + 9,
                -text   => $time_lbl,
                -fill   => '#ffffff',
                -anchor => 'center',
                -font   => 'TkFixedFont 8 bold',
                -tags   => ['price_cross']);
        }
    }

    $canvas->raise('price_cross');
}

# -----------------------------------------------------------------------------
# _draw_atr_cross
# Cruz persistente del panel ATR. Misma logica que la del precio pero
# usando el scale del ATR (relativo, offset=0).
# -----------------------------------------------------------------------------
sub _draw_atr_cross {
    my ($self) = @_;
    my $cross  = $self->{_atr_cross};
    my $canvas = $self->{canvas_atr};
    my $scale  = $self->{_scale_atr};

    $canvas->delete('atr_cross');
    return unless defined $cross && $scale;

    my $color = '#b71c1c';   # rojo bordo (igual que la linea del ATR)

    # El scale del ATR es relativo: rel_idx = abs_idx - offset_global
    my $rel_idx = $cross->{idx} - $self->{offset};
    my $x       = $scale->index_to_center_x($rel_idx);
    my $y       = $scale->value_to_y($cross->{value});

    my $x_sep = $scale->_plot_w;
    my $x_end = $scale->{canvas_w};

    my $idx_in_view = ($rel_idx >= 0
                    && $rel_idx <  $scale->{visible_bars}
                    && $x >= 0 && $x <= $x_sep);

    if ($idx_in_view) {
        $canvas->createLine($x, 0, $x, $scale->{canvas_h},
            -fill => $color, -dash => [4, 3], -width => 1,
            -tags => ['atr_cross']);
    }

    if ($scale->value_in_range($cross->{value})) {
        $canvas->createLine(0, $y, $x_sep, $y,
            -fill => $color, -dash => [4, 3], -width => 1,
            -tags => ['atr_cross']);

        # Caja en regleta Y con el valor ATR
        $canvas->createRectangle($x_sep+1, $y-9, $x_end-1, $y+9,
            -fill => $color, -outline => $color,
            -tags => ['atr_cross']);
        $canvas->createText($x_sep + ($x_end - $x_sep) / 2, $y,
            -text   => sprintf('%.4f', $cross->{value}),
            -fill   => '#ffffff',
            -anchor => 'center',
            -font   => 'TkFixedFont 8 bold',
            -tags   => ['atr_cross']);
    }

    $canvas->raise('atr_cross');
}

# -----------------------------------------------------------------------------
# _format_time_for_axis  (helper)
# Convierte un timestamp ISO ("2026-04-01T03:45:00-05:00") en una etiqueta
# corta para mostrar en la regleta X: "01/04 03:45".
# -----------------------------------------------------------------------------
sub _format_time_for_axis {
    my ($iso) = @_;
    return '' unless defined $iso;
    if ($iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/) {
        return sprintf('%s/%s %s:%s', $3, $2, $4, $5);
    }
    return $iso;
}

# -----------------------------------------------------------------------------
# _vertical_drag
# Desplazamiento vertical (pan) del rango de precios cuando se arrastra con
# el boton derecho.
# -----------------------------------------------------------------------------
sub _vertical_drag {
    my ($self, $dy) = @_;
    return unless $self->{y_range_price};
    my ($mn, $mx) = @{ $self->{y_range_price} };
    my $plot_h = $self->{canvas_price_h} - 10 - TIME_AXIS_H;
    return if $plot_h <= 0;
    my $delta = $dy / $plot_h * ($mx - $mn);
    my ($new_mn, $new_mx) = $self->_clamp_price_range($mn + $delta, $mx + $delta);
    $self->{y_range_price} = [$new_mn, $new_mx];
    $self->request_render;
}

sub _vertical_drag_atr {
    my ($self, $dy) = @_;
    return unless $self->{y_range_atr};
    my ($mn, $mx) = @{ $self->{y_range_atr} };
    my $plot_h = $self->{canvas_atr_h};
    return if $plot_h <= 0;
    my $delta = $dy / $plot_h * ($mx - $mn);
    my ($new_mn, $new_mx) = $self->_clamp_atr_range($mn + $delta, $mx + $delta);
    $self->{y_range_atr} = [$new_mn, $new_mx];
    $self->request_render;
}

# -----------------------------------------------------------------------------
# _vertical_zoom_price / _vertical_zoom_atr
# Zoom vertical alrededor del centro del rango actual.
# -----------------------------------------------------------------------------
sub _vertical_zoom_price {
    my ($self, $factor) = @_;
    $self->{zoom_y_auto} = 0;
    my ($mn, $mx);
    if ($self->{y_range_price}) {
        ($mn, $mx) = @{ $self->{y_range_price} };
    } else {
        my ($s, $e) = $self->compute_window;
        my $vis = $self->{market}->get_slice($s, $e);
        ($mn, $mx) = $self->{price_panel}->get_y_range($vis);
    }
    my $mid  = ($mn + $mx) / 2;
    my $half = ($mx - $mn) / 2 * $factor;
    my ($new_mn, $new_mx) = $self->_clamp_price_range($mid - $half, $mid + $half);
    $self->{y_range_price} = [$new_mn, $new_mx];
    $self->request_render;
}

sub _vertical_zoom_atr {
    my ($self, $factor) = @_;
    $self->{zoom_y_auto_atr} = 0;
    my ($mn, $mx);
    if ($self->{y_range_atr}) {
        ($mn, $mx) = @{ $self->{y_range_atr} };
    } else {
        my ($s, $e) = $self->compute_window;
        my $vis_atr = $self->{indicators}->slice_array('atr', $s, $e);
        ($mn, $mx)  = $self->{atr_panel}->get_y_range($vis_atr);
    }
    my $mid  = ($mn + $mx) / 2;
    my $half = ($mx - $mn) / 2 * $factor;
    my ($new_mn, $new_mx) = $self->_clamp_atr_range($mid - $half, $mid + $half);
    $self->{y_range_atr} = [$new_mn, $new_mx];
    $self->request_render;
}

# -----------------------------------------------------------------------------
# _draw_crosshair_all
# Sincroniza el crosshair entre AMBOS paneles:
#   - Eje X (linea vertical): aparece en los DOS paneles, en la misma X.
#   - Eje Y (linea horizontal + caja de valor): solo en el panel donde
#     esta el cursor (cada panel tiene su propia escala Y).
#   - OHLCV label del panel de precios: se actualiza cuando el cursor
#     esta en CUALQUIERA de los dos paneles (la X define la vela).
# -----------------------------------------------------------------------------
sub _draw_crosshair_all {
    my ($self) = @_;
    my $x     = $self->{_mouse_x};
    my $y     = $self->{_mouse_y};
    my $y_atr = $self->{_mouse_y_atr};
    return if $x < 0;

    # Info de la vela bajo el cursor (la misma para ambos paneles)
    my $candle_info;
    if ($self->{_scale_price}) {
        my $idx = $self->{_scale_price}->x_to_index($x);
        $candle_info = $self->{market}->get_candle($idx);
    }

    # --- Panel precios ---
    if ($self->{_scale_price} && $self->{price_panel}{_cross_ready}) {
        if ($self->{_mouse_in_price}) {
            # Cursor aqui: crosshair completo
            my $snap_idx = $self->{_scale_price}->x_to_index($x);
            my $snap_x   = $self->{_scale_price}->index_to_center_x($snap_idx);
            $self->{price_panel}->draw_crosshair($snap_x, $y, $candle_info);
        } elsif ($self->{_mouse_in_atr}) {
            # Cursor en el ATR: solo vline aqui, sin hline
            my $snap_idx = $self->{_scale_price}->x_to_index($x);
            my $snap_x   = $self->{_scale_price}->index_to_center_x($snap_idx);
            $self->{price_panel}->show_vline_only($snap_x);
            $self->{price_panel}->show_ohlcv_info($candle_info) if $candle_info;
        } else {
            $self->{price_panel}->hide_crosshair;
        }
    }

    # --- Panel ATR ---
    if ($self->{_scale_atr} && $self->{atr_panel}{_cross_ready}) {
        if ($self->{_mouse_in_atr}) {
            # Cursor aqui: crosshair completo
            my $snap_idx = $self->{_scale_atr}->x_to_index($x);
            my $snap_x   = $self->{_scale_atr}->index_to_center_x($snap_idx);
            $self->{atr_panel}->draw_crosshair($snap_x, $y_atr);
        } elsif ($self->{_mouse_in_price}) {
            # Cursor en precios: solo vline aqui, sin hline
            my $snap_idx = $self->{_scale_atr}->x_to_index($x);
            my $snap_x   = $self->{_scale_atr}->index_to_center_x($snap_idx);
            $self->{atr_panel}->show_vline_only($snap_x);
        } else {
            $self->{atr_panel}->hide_crosshair;
        }
    }
}

# -----------------------------------------------------------------------------
# set_timeframe
# Cambia la temporalidad: reconstruye indicadores y resetea la vista.
# -----------------------------------------------------------------------------
sub set_timeframe {
    my ( $self, $tf ) = @_;
    $self->{market}->set_timeframe($tf);
    $self->{indicators}->reset_all;
    $self->{indicators}->rebuild_all($self->{market});
    $self->reset_view;
    $self->request_render;
}

# -----------------------------------------------------------------------------
# reset_view
# Vuelve al estado inicial: zoom horizontal default, autozoom Y, ultima
# vela alineada al borde derecho.
# -----------------------------------------------------------------------------
sub reset_view {
    my ($self) = @_;
    $self->{visible_bars}    = DEFAULT_BARS;
    $self->{zoom_y_auto}     = 1;
    $self->{y_range_price}   = undef;
    $self->{zoom_y_auto_atr} = 1;
    $self->{y_range_atr}     = undef;
    $self->{_scale_price}    = undef;
    $self->{_scale_atr}      = undef;
    $self->{_price_cross}    = undef;
    $self->{_atr_cross}      = undef;

    my $total = $self->{market}->size;
    $self->{offset} = $total - DEFAULT_BARS;
    $self->{offset} = 0 if $self->{offset} < 0;
}

# -----------------------------------------------------------------------------
# compute_intraday_labels
# Combina las anclas "naturales" (cambio de dia/hora del MarketData) con
# anclas INTERMEDIAS automaticas que se distribuyen uniformemente para
# llenar el eje cuando los cambios de hora estan muy espaciados.
#
# Objetivo: ~20 etiquetas visibles, adaptadas al zoom actual.
# -----------------------------------------------------------------------------
sub compute_intraday_labels {
    my ($self, $start, $end) = @_;

    # 1) Anclas naturales del MarketData (cambios de dia/hora)
    my $all  = $self->{market}->compute_time_anchors;
    my @nat  = grep { $_->{index} >= $start && $_->{index} <= $end } @$all;

    # 2) Calcular cuantas etiquetas caben visualmente (~20)
    my $visible = $end - $start + 1;
    return \@nat if $visible <= 0;

    my $target = 20;
    my $stride = int($visible / $target);
    $stride    = 1 if $stride < 1;

    # 3) Marcar indices ya ocupados por anclas naturales
    my %used;
    for my $a (@nat) { $used{ $a->{index} } = 1; }

    # 4) Generar anclas intermedias en multiplos de $stride.
    my @intermediate;
    my $i = $start;
    while ($i <= $end) {
        unless ($used{$i}) {
            my $candle = $self->{market}->get_candle($i);
            if ($candle && defined $candle->{time}) {
                my $lbl = '';
                if ($candle->{time} =~ /T(\d{2}):(\d{2})/) {
                    $lbl = "$1:$2";
                }
                push @intermediate, {
                    index => $i,
                    label => $lbl,
                    ts    => $candle->{ts},
                };
            }
        }
        $i += $stride;
    }

    # 5) Combinar y ordenar por indice
    my @combined = sort { $a->{index} <=> $b->{index} } (@nat, @intermediate);

    # 6) Filtro anti-colision: si dos anclas quedan muy cerca (< stride/2),
    # priorizar la natural (cambio de hora/dia).
    my @final;
    my $last_idx = -999999;
    my $min_gap  = int($stride / 2);
    $min_gap     = 1 if $min_gap < 1;
    for my $a (@combined) {
        if ($a->{index} - $last_idx >= $min_gap) {
            push @final, $a;
            $last_idx = $a->{index};
        }
    }
    return \@final;
}

# -----------------------------------------------------------------------------
# get_all_timestamps
# Lista de epochs de las velas visibles. Util para sincronizacion / debug.
# -----------------------------------------------------------------------------
sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window;
    my $slice = $self->{market}->get_slice($start, $end);
    return [ map { $_->{ts} } @$slice ];
}

1;
