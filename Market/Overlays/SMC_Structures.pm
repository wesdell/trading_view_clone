package Market::Overlays::SMC_Structures;

# =============================================================================
# Market::Overlays::SMC_Structures
#
# Renderiza todo lo calculado por Indicators/SMC_Structures.pm:
#   - HH/HL/LH/LL: etiquetas sobre/bajo cada swing + linea zigzag
#   - BOS / CHoCH: linea horizontal + chip de color
#       BOS  bull  = verde teal  | BOS  bear  = rojo
#       CHoCH bull = azul        | CHoCH bear = naranja  (colores distintos)
#   - FVG: caja que empieza DESPUES de la 3a vela, solo los 'significant',
#           con desvanecimiento progresivo por edad y consumo parcial
#   - Order Blocks: cajas de demand/supply, solo cuando el precio esta
#           dentro de ob_proximity_mult*ATR; si coincide con FVG muestra "OB"
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);

use constant TAG => 'overlay_smc';

# Sub-tags de las ZONAS (rectangulos) que deben quedar DETRAS de las velas.
# ChartEngine las baja bajo el tag 'candle' tras dibujar el overlay, para que
# FVG/OB no tapen cuerpos ni mechas (los chips/etiquetas siguen al frente).
use constant TAG_FVG => 'smc_fvg_zone';
use constant TAG_OB  => 'smc_ob_zone';

use constant {
    C_BOS_UP    => '#26a69a',   # BOS alcista   (verde teal)
    C_BOS_DN    => '#ef5350',   # BOS bajista   (rojo)
    C_CHOCH_UP  => '#2962ff',   # CHoCH alcista (azul)
    C_CHOCH_DN  => '#ff6d00',   # CHoCH bajista (naranja)
    C_HH_HL     => '#26a69a',   # HH/HL labels  (alcista = verde)
    C_LH_LL     => '#ef5350',   # LH/LL labels  (bajista = rojo)
    C_ZIGZAG    => '#546e7a',   # linea zigzag  (gris azulado, legacy)
    # PDF "direccion interna/externa": zigzag INTERNO (fino) verde=subida /
    # rojo=bajada; zigzag EXTERNO (estructura mayor compactada) en azul.
    C_ZZ_INT_UP => '#26a69a',   # zigzag interno: pierna alcista (verde)
    C_ZZ_INT_DN => '#ef5350',   # zigzag interno: pierna bajista (rojo)
    C_ZZ_EXT    => '#2962ff',   # zigzag externo / estructura mayor (azul)
    C_OB_BULL   => '#81c784',   # OB alcista (demand)
    C_OB_BEAR   => '#e57373',   # OB bajista (supply)
};

sub new {
    my ($class, %args) = @_;
    bless {
        source      => $args{source},
        max_age     => $args{max_age}    // 50,
        show_struct => $args{show_struct} // 1,
        show_fvg    => $args{show_fvg}   // 1,
        show_bos    => $args{show_bos}   // 1,
        show_choch  => $args{show_choch} // 1,
        show_obs    => $args{show_obs}   // 1,
    }, $class;
}

sub tag { return TAG; }

sub set_flag {
    my ($self, $flag, $val) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub render {
    my ($self, $canvas, $scale, $placer) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source} or return;

    # $placer (opcional): las etiquetas se ENCOLAN en el LabelPlacer compartido
    # y ChartEngine las coloca al final evitando velas y otras etiquetas. Si no
    # se pasa placer, se cae al chip inmediato de siempre (compatibilidad).
    $self->_render_fvgs($canvas, $scale, $src, $placer)   if $self->{show_fvg};
    $self->_render_obs($canvas, $scale, $src, $placer)    if $self->{show_obs};
    $self->_render_struct($canvas, $scale, $src, $placer) if $self->{show_struct};
    $self->_render_events($canvas, $scale, $src, $placer)
        if $self->{show_bos} || $self->{show_choch};
}

# _label: encola una etiqueta en el placer (anti-solape global) o, si no hay
# placer, la dibuja inmediatamente con el chip clasico.
sub _label {
    my ($self, $placer, $canvas, $x, $y, $text, %o) = @_;
    if ($placer) {
        $placer->add(
            x => $x, y => $y, text => $text,
            color => $o{color}, style => $o{style}, side => $o{side},
            priority => $o{priority}, hideable => $o{hideable}, font => $o{font},
        );
    } else {
        $self->_chip($canvas, $x, $y, $text,
            -color => $o{color}, -style => $o{style},
            -place => $o{side}, -font => $o{font});
    }
}

# =============================================================================
# HH / HL / LH / LL  +  zigzag
# =============================================================================
sub _render_struct {
    my ($self, $canvas, $scale, $src, $placer) = @_;
    my $swings = $src->get_struct_swings or return;
    return unless @$swings;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;   # borde derecho del area de grafico (regleta a la derecha)

    # --- DOS zigzags de direccion (spec PDF "direccion interna/externa") ---
    # Se incluye el pivote ANTERIOR y POSTERIOR a la ventana para que las
    # piernas que la cruzan se dibujen completas. Todo se recorta a [0, plot_w]
    # para no invadir la regleta de precios.
    my ($lo, $hi) = ($off - 1, $off + $vb + 1);

    # 1) Zigzag INTERNO (direccion interna): usa TODOS los pivotes estructurales
    #    finos (get_struct_swings) y colorea cada segmento segun su direccion:
    #    verde = pierna alcista (hacia un High), rojo = pierna bajista.
    my @iv = _visible_pivots($swings, $lo, $hi);
    for my $s (1 .. $#iv) {
        my $a = $iv[$s-1]; my $b = $iv[$s];
        my $up    = ($b->{kind} eq 'H');   # llega a un High -> pierna alcista
        my $color = $up ? C_ZZ_INT_UP : C_ZZ_INT_DN;
        $self->_seg_clipped($canvas, $scale, $a, $b, 0, $plot_w, $color, 1);
    }

    # 2) Zigzag EXTERNO (direccion externa = ESTRUCTURA MAYOR compactada):
    #    une directamente origen->extremo de cada tramo fuerte (LL->HH directo)
    #    y se pinta en AZUL, mas grueso, por encima del interno. Las etiquetas
    #    HH/HL/LH/LL de abajo siguen sobre los pivotes crudos (no se pierde detalle).
    my $main = $src->can('get_main_struct') ? $src->get_main_struct : $swings;
    my @ev = _visible_pivots($main, $lo, $hi);
    my @pts;
    for my $p (@ev) {
        push @pts, $scale->index_to_center_x($p->{index}),
                   $scale->value_to_y_raw($p->{price});
    }
    @pts = _clip_polyline_x(\@pts, 0, $plot_w);
    if (@pts >= 4) {
        $canvas->createLine(@pts,
            -fill  => C_ZZ_EXT,
            -width => 2,
            -tags  => [TAG]);
    }

    # --- Etiquetas HH / HL / LH / LL ---
    # El punto (circulo) siempre se dibuja para marcar el vertice del zigzag,
    # pero el TEXTO se omite si hay otra etiqueta del mismo lado demasiado cerca
    # en horizontal (spec 10: no mostrar etiquetas demasiado juntas). Los highs
    # etiquetan ARRIBA y los lows ABAJO -> no tapan las velas.
    my (@lbl_hi, @lbl_lo);   # posiciones X de etiquetas ya puestas por lado
    for my $sw (@$swings) {
        next if $sw->{index} < $off || $sw->{index} > $off + $vb;
        next unless $scale->value_in_range($sw->{price});

        my $x     = $scale->index_to_center_x($sw->{index});
        next if $x < 0 || $x > $plot_w;   # fuera del area de grafico (no tapar la regleta)
        my $y     = $scale->value_to_y($sw->{price});
        my $up    = ($sw->{kind} eq 'H');
        my $color = ($sw->{label} eq 'HH' || $sw->{label} eq 'HL') ? C_HH_HL : C_LH_LL;

        # Punto de pivote (circulo pequeno)
        $canvas->createOval($x-3, $y-3, $x+3, $y+3,
            -fill => $color, -outline => $color, -tags => [TAG]);

        my $slot = $up ? \@lbl_hi : \@lbl_lo;
        my $too_close = grep { abs($_ - $x) < 26 } @$slot;
        next if $too_close;
        push @$slot, $x;

        $self->_label($placer, $canvas, $x, $y, $sw->{label},
            color => $color, style => 'outline',
            side  => ($up ? 'above' : 'below'),
            priority => 5, hideable => 1,
            font => 'TkDefaultFont 7 bold');
    }
}

# =============================================================================
# FVG: la caja empieza en idx_create (despues de la 3a vela), desaparece
# al consumirse, y solo muestra los 'significant' con un minimo de ATR.
# Si el area tambien tiene un OB activo, muestra chip "OB" en lugar de "FVG".
# =============================================================================
sub _render_fvgs {
    my ($self, $canvas, $scale, $src, $placer) = @_;
    my $fvgs = $src->get_fvgs or return;
    my $last_known = $src->processed_last;
    my $max_age    = $self->{max_age};

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $bar_w  = $plot_w / $scale->{visible_bars};
    my $last_close = $scale->{last_close} // 0;

    # Obtener OBs activos para detectar overlap
    my $obs = $src->get_order_blocks // [];
    my @active_obs = grep { $_->{state} eq 'active' } @$obs;

    for my $f (@$fvgs) {
        next unless $f->{significant};
        # Solo se dibujan FVG ACTIVOS: al mitigarse (consumo completo) o expirar
        # desaparecen (spec 13.5). El encogimiento progresivo se hace con la
        # frontera consumed_to que mantiene el indicador.
        next if $f->{state} ne 'active';

        my $age = $last_known - $f->{created};
        next if $age > $max_age;

        # Zona RESTANTE (no consumida): se encoge conforme el precio penetra.
        my $ct = $f->{consumed_to};
        my ($rem_top, $rem_bottom);
        if ($f->{dir} eq 'bull') {
            $rem_top    = defined $ct ? $ct : $f->{top};
            $rem_bottom = $f->{bottom};
        } else {
            $rem_top    = $f->{top};
            $rem_bottom = defined $ct ? $ct : $f->{bottom};
        }
        next if ($rem_top - $rem_bottom) <= 0;   # ya consumido

        # Borde derecho
        my $right_idx = $f->{created} + $max_age;
        $right_idx = $last_known if $right_idx > $last_known;
        next if $right_idx < $off;
        next if $f->{idx_create} > $off + $vb;

        next unless $scale->value_in_range($rem_top)
                 || $scale->value_in_range($rem_bottom)
                 || ($rem_bottom < $scale->{min_val} && $rem_top > $scale->{max_val});

        # Borde izquierdo: DESPUES de la 3a vela (idx_create)
        my $x1 = $scale->index_to_center_x($f->{idx_create}) + $bar_w * 0.5;
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y($rem_top);
        my $yb = $scale->value_to_y($rem_bottom);
        next if $yb - $yt < 2;   # zona demasiado delgada en pixels, omitir

        # PRIORIDAD OB > FVG (spec 15): si un OB activo comparte esta banda de
        # precio, NO se dibuja el FVG (el OB domina visualmente esa zona).
        my $under_ob = 0;
        for my $ob (@active_obs) {
            my $ob_yt = $scale->value_to_y($ob->{zone_high});
            my $ob_yb = $scale->value_to_y($ob->{zone_low});
            next if $ob_yb < $yt || $ob_yt > $yb;   # sin overlap vertical
            $under_ob = 1; last;
        }
        next if $under_ob;

        # Desvanecimiento por edad
        my $fresh = 1 - ($age / $max_age);
        $fresh = 0 if $fresh < 0;

        my $base = ($f->{dir} eq 'bull') ? '#26a69a' : '#ef5350';
        my $fill = _mix($base, 0.05 + 0.10 * $fresh);
        my $line = _mix($base, 0.25 + 0.25 * $fresh);

        $canvas->createRectangle($x1, $yt, $x2, $yb,
            -fill => $fill, -outline => $line, -width => 1, -tags => [TAG, TAG_FVG]);

        # Chip "FVG" (solo si la caja restante es suficientemente alta y no muy
        # vieja). Las zonas con OB ya se saltaron arriba, asi que aqui siempre
        # es FVG puro.
        if (($yb - $yt) >= 14 && $age <= int($max_age * 0.6)) {
            my $cx = ($x1 + $x2) / 2;
            $cx = 24 if $cx < 24;
            $self->_label($placer, $canvas, $cx, ($yt + $yb) / 2, 'FVG',
                color => $base, style => 'outline', side => 'center',
                priority => 7, hideable => 1,
                font => 'TkDefaultFont 6 bold');
        }
    }
}

# =============================================================================
# Order Blocks: demand (bull) o supply (bear), solo cuando el precio esta
# cerca (dentro de ob_proximity_mult * ATR). Soporte abajo, resistencia arriba.
# =============================================================================
sub _render_obs {
    my ($self, $canvas, $scale, $src, $placer) = @_;
    my $obs = $src->get_order_blocks or return;
    return unless @$obs;

    my $off       = $scale->{offset};
    my $vb        = $scale->{visible_bars};
    my $plot_w    = $scale->_plot_w;
    my $last_close = $scale->{last_close} // 0;

    # ATR aproximado: usar el rango de precio visible como proxy si no disponible
    my $price_range = $scale->{max_val} - $scale->{min_val};
    my $atr_proxy   = $price_range * 0.05;   # 5% del rango visible como ATR aproximado

    my $proximity = $self->{source}{ob_proximity_mult} // 6.0;

    for my $ob (@$obs) {
        next if $ob->{state} eq 'broken';

        # Solo mostrar si el precio esta cerca del OB
        my $dist = ($ob->{dir} eq 'bull')
            ? $last_close - $ob->{zone_high}
            : $ob->{zone_low} - $last_close;
        next if $dist > $proximity * $atr_proxy && $last_close != 0;
        next if $dist < -$atr_proxy * 2;   # precio ya paso a traves del OB

        next unless $scale->value_in_range($ob->{zone_high})
                 || $scale->value_in_range($ob->{zone_low});

        # X: desde el indice del OB hasta el borde derecho visible
        my $x1 = $scale->index_to_center_x($ob->{idx});
        my $x2 = $plot_w;
        $x1 = 0 if $x1 < 0;
        next if $x1 >= $plot_w;

        my $yt = $scale->value_to_y($ob->{zone_high});
        my $yb = $scale->value_to_y($ob->{zone_low});
        next if $yb - $yt < 2;

        my $color = ($ob->{dir} eq 'bull') ? C_OB_BULL : C_OB_BEAR;
        my $fill  = _mix($color, 0.15);

        $canvas->createRectangle($x1, $yt, $x2, $yb,
            -fill    => $fill,
            -outline => $color,
            -width   => 1,
            -dash    => [4, 3],
            -tags    => [TAG, TAG_OB]);

        # Etiqueta "OB" en el lado izquierdo de la zona (maxima prioridad)
        my $cy = ($yt + $yb) / 2;
        my $label = ($ob->{dir} eq 'bull') ? 'OB+' : 'OB-';
        $self->_label($placer, $canvas, $x1 + 20, $cy, $label,
            color => $color, style => 'solid', side => 'center',
            priority => 1, hideable => 0,
            font => 'TkDefaultFont 7 bold');
    }
}

# =============================================================================
# BOS / CHoCH: linea horizontal del pivote al punto de ruptura + chip.
# Colores distintos por tipo Y direction:
#   BOS  up   = teal   | BOS  down  = rojo
#   CHoCH up  = azul   | CHoCH down = naranja
# =============================================================================
sub _render_events {
    my ($self, $canvas, $scale, $src, $placer) = @_;
    my $events = $src->get_events or return;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    for (my $k = $#$events; $k >= 0; $k--) {
        my $e        = $events->[$k];
        my $is_choch = ($e->{type} eq 'CHoCH');

        next if !$is_choch && !$self->{show_bos};
        next if  $is_choch && !$self->{show_choch};

        next if $e->{index} < $off || $e->{index} > $off + $vb;
        next unless $scale->value_in_range($e->{price});

        my $color;
        if ($is_choch) {
            $color = ($e->{dir} eq 'up') ? C_CHOCH_UP : C_CHOCH_DN;
        } else {
            $color = ($e->{dir} eq 'up') ? C_BOS_UP   : C_BOS_DN;
        }

        my $oi = defined($e->{origin}) ? $e->{origin} : $e->{index} - 6;
        my $x1 = $scale->index_to_center_x($oi);
        my $x2 = $scale->index_to_center_x($e->{index});
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $y = $scale->value_to_y($e->{price});

        $canvas->createLine($x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            ($is_choch ? (-dash => [5, 3]) : ()),
            -tags  => [TAG]);

        my $up = ($e->{dir} eq 'up');
        $self->_label($placer, $canvas, ($x1 + $x2) / 2, $y, $e->{label},
            color => $color, style => 'solid',
            side  => ($up ? 'above' : 'below'),
            priority => 2, hideable => 0,
            font => 'TkDefaultFont 8 bold');
    }
}

# =============================================================================
# _chip: etiqueta tipo TradingView (igual que en la version anterior).
# =============================================================================
sub _chip {
    my ($self, $canvas, $cx, $cy, $text, %o) = @_;
    my $color  = $o{-color}  // '#363a45';
    my $style  = $o{-style}  // 'solid';
    my $place  = $o{-place}  // 'above';
    my $off    = defined $o{-offset} ? $o{-offset} : 9;
    my $font   = $o{-font}   // ($style eq 'solid' ? 'TkDefaultFont 12 bold' : 'TkDefaultFont 7 bold');
    my $placed = $o{-placed};
    my $pad    = 2;

    my $ty = $place eq 'below'  ? $cy + $off
           : $place eq 'center' ? $cy
           :                      $cy - $off;

    my $tid = $canvas->createText($cx, $ty,
        -text   => $text,
        -anchor => 'center',
        -font   => $font,
        -fill   => ($style eq 'solid' ? '#ffffff' : $color),
        -tags   => [TAG]);

    my @bb = $canvas->bbox($tid);
    return unless @bb;
    my ($x1, $y1, $x2, $y2) = @bb;
    $x1 -= $pad; $x2 += $pad; $y1 -= 1; $y2 += 1;

    if ($placed) {
        my $dir = ($place eq 'below') ? 1 : -1;
        my $h   = ($y2 - $y1) + 2;
        my $t   = 0;
        while ($t++ < 6 && _box_hits([$x1,$y1,$x2,$y2], $placed)) {
            my $shift = $dir * $h;
            $_ += $shift for ($y1, $y2);
            $canvas->move($tid, 0, $shift);
        }
        push @$placed, [$x1,$y1,$x2,$y2];
    }

    my $fill = ($style eq 'solid') ? $color : '#ffffff';
    my $rid  = $canvas->createRectangle($x1,$y1,$x2,$y2,
        -fill => $fill, -outline => $color, -width => 1, -tags => [TAG]);
    $canvas->lower($rid, $tid);
}

sub _box_hits {
    my ($b, $list) = @_;
    for my $o (@$list) {
        next if $b->[2] < $o->[0] || $b->[0] > $o->[2]
             || $b->[3] < $o->[1] || $b->[1] > $o->[3];
        return 1;
    }
    return 0;
}

# -----------------------------------------------------------------------------
# _visible_pivots: pivotes de $list dentro de [lo,hi] MAS un pivote bracketing
# a cada lado (el ultimo antes de lo y el primero despues de hi), para que las
# piernas que cruzan la ventana se dibujen completas.
# -----------------------------------------------------------------------------
sub _visible_pivots {
    my ($list, $lo, $hi) = @_;
    my @out;
    my $prev;
    for my $sw (@$list) {
        if ($sw->{index} < $lo) { $prev = $sw; next; }
        if (defined $prev) { push @out, $prev; $prev = undef; }
        push @out, $sw;
        last if $sw->{index} > $hi;   # ya incluido el primero > hi
    }
    return @out;
}

# -----------------------------------------------------------------------------
# _seg_clipped: dibuja el segmento pivote $a -> $b (X creciente) recortado a
# [xmin,xmax], interpolando la Y en los bordes (no invade la regleta).
# -----------------------------------------------------------------------------
sub _seg_clipped {
    my ($self, $canvas, $scale, $a, $b, $xmin, $xmax, $color, $width) = @_;
    my $x1 = $scale->index_to_center_x($a->{index});
    my $y1 = $scale->value_to_y_raw($a->{price});
    my $x2 = $scale->index_to_center_x($b->{index});
    my $y2 = $scale->value_to_y_raw($b->{price});
    return if $x2 < $xmin || $x1 > $xmax;   # totalmente fuera del area
    if ($x2 > $xmax && $x2 != $x1) { my $t = ($xmax-$x1)/($x2-$x1); $x2 = $xmax; $y2 = $y1 + $t*($y2-$y1); }
    if ($x1 < $xmin && $x1 != $x2) { my $t = ($xmin-$x2)/($x1-$x2); $x1 = $xmin; $y1 = $y2 + $t*($y1-$y2); }
    $canvas->createLine($x1, $y1, $x2, $y2,
        -fill => $color, -width => ($width // 1), -tags => [TAG]);
}

# -----------------------------------------------------------------------------
# _clip_polyline_x: recorta una polilinea (@pts = x0,y0,x1,y1,...) al rango
# horizontal [xmin, xmax], interpolando la Y en los cruces de borde. Los
# pivotes vienen en X estrictamente creciente (orden por indice), asi que solo
# hay UN cruce de entrada (izq) y UNO de salida (der). Evita que la linea se
# meta en la regleta de precios (a la derecha de xmax = _plot_w).
# -----------------------------------------------------------------------------
sub _clip_polyline_x {
    my ($pts, $xmin, $xmax) = @_;
    my $n = int(@$pts / 2);
    return () if $n < 2;

    my @out;
    for (my $i = 0; $i < $n; $i++) {
        my ($x, $y) = ($pts->[2*$i], $pts->[2*$i+1]);

        if ($x < $xmin) {
            # cruce de entrada por la izquierda: interpolar en xmin con el siguiente
            if ($i + 1 < $n) {
                my ($nx, $ny) = ($pts->[2*$i+2], $pts->[2*$i+3]);
                if ($nx > $x && $nx >= $xmin) {
                    my $t = ($xmin - $x) / ($nx - $x);
                    push @out, $xmin, $y + $t * ($ny - $y);
                }
            }
            next;
        }
        if ($x > $xmax) {
            # cruce de salida por la derecha: interpolar en xmax con el anterior
            if ($i > 0) {
                my ($px, $py) = ($pts->[2*$i-2], $pts->[2*$i-1]);
                if ($px < $x && $px <= $xmax) {
                    my $t = ($xmax - $px) / ($x - $px);
                    push @out, $xmax, $py + $t * ($y - $py);
                }
            }
            last;   # X monotona creciente: ya no hay mas puntos dentro del rango
        }
        push @out, $x, $y;
    }
    return @out;
}

# Mezcla hex con fondo blanco segun opacidad
sub _mix {
    my ($hex, $op) = @_;
    $op = 0 if $op < 0; $op = 1 if $op > 1;
    my ($r,$g,$b) = (hex(substr($hex,1,2)), hex(substr($hex,3,2)), hex(substr($hex,5,2)));
    my $f = 1 - $op;
    return sprintf('#%02x%02x%02x',
        int($r + (255-$r)*$f), int($g + (255-$g)*$f), int($b + (255-$b)*$f));
}

1;