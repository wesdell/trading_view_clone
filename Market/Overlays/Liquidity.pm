package Market::Overlays::Liquidity;

# =============================================================================
# Market::Overlays::Liquidity   (Tabla 1 del PDF)
#
# Capa visual del modulo de liquidez. Lee lo ya calculado por
# Indicators/Liquidity.pm (swings, niveles BSL/SSL, EQH/EQL y eventos
# Sweep/Grab/Run) y lo dibuja segun la Tabla 2 del PDF. NO calcula nada.
#
# Estilo de etiquetas: igual que el proyecto de referencia (helper _chip):
#   - outline : texto de color sobre chip blanco con borde de color ->
#               niveles resting BSL/SSL y EQH/EQL (sobrios, junto al evento).
#   - solid   : texto blanco sobre chip de color -> eventos resueltos
#               Sweep / Grab / Run (destacados).
#   Anti-solape que DESPLAZA la etiqueta verticalmente (no la borra). Las
#   etiquetas se anclan a la coordenada X/precio reales -> estables en
#   replay/zoom/desplazamiento.
#
#   BSL/SSL : linea horizontal punteada (rojo/verde) que se extiende a la
#             derecha; chip "BSL"/"SSL" junto a la regleta.
#   EQH/EQL : linea que conecta los dos pivotes iguales + chip.
#   Sweep/Grab/Run : marcador en la vela de resolucion + chip de color.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Sub-toggles: show_swing/show_bsl/show_ssl/show_eqh/show_eql/show_sweeps/
#   show_grabs/show_runs.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_liquidity';

use constant {
    C_BSL    => '#ef5350',   # rojo    (Buy Side Liquidity)
    C_SSL    => '#26a69a',   # verde   (Sell Side Liquidity)
    C_EQ     => '#7e57c2',   # violeta (EQH/EQL, configurable)
    C_GRAB   => '#ff9800',   # naranja (Liquidity Grab)
    C_RUN    => '#2962ff',   # azul    (Liquidity Run)
    MAX_LINES   => 6,        # niveles BSL/SSL resting dibujados (mas recientes)
    MAX_EVENTS  => 50,       # eventos recientes considerados por render
    CLUSTER_GAP => 3,        # FIX-LQ2b: velas de tolerancia para agrupar eventos
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source      => $args{source},
        show_swing  => $args{show_swing}  // 1,
        show_bsl    => $args{show_bsl}    // 1,
        show_ssl    => $args{show_ssl}    // 1,
        show_eqh    => $args{show_eqh}    // 1,
        show_eql    => $args{show_eql}    // 1,
        show_sweeps => $args{show_sweeps} // 1,
        show_grabs  => $args{show_grabs}  // 1,
        show_runs   => $args{show_runs}   // 1,
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
    my $src = $self->{source};
    return unless $src;

    my @placed;   # cajas [x1,y1,x2,y2] de etiquetas ya colocadas (anti-solape)
    $self->_render_swings( $canvas, $scale, $src )            if $self->{show_swing};
    $self->_render_levels( $canvas, $scale, $src, \@placed );
    $self->_render_equals( $canvas, $scale, $src, \@placed )
        if $self->{show_eqh} || $self->{show_eql};
    $self->_render_events( $canvas, $scale, $src, \@placed );
}

# -----------------------------------------------------------------------------
# Niveles BSL/SSL "resting" (aun no barridos): linea horizontal punteada que se
# extiende a la derecha; chip outline "BSL"/"SSL" junto a la regleta de precio.
# -----------------------------------------------------------------------------
sub _render_levels {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $levels = $src->get_levels or return;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $x_lim  = $off + $vb;

    for my $kind ( 'buy', 'sell' ) {
        next if $kind eq 'buy'  && !$self->{show_bsl};
        next if $kind eq 'sell' && !$self->{show_ssl};

        my @resting = grep {
            $_->{side} eq $kind && $_->{state} ne 'RESOLVED'
        } @$levels;
        @resting = @resting[ -MAX_LINES .. -1 ] if @resting > MAX_LINES;

        my $color = ( $kind eq 'buy' ) ? C_BSL : C_SSL;
        my $text  = ( $kind eq 'buy' ) ? 'BSL' : 'SSL';

        for my $lv (@resting) {
            next if $lv->{index} > $x_lim;
            next unless $scale->value_in_range( $lv->{price} );

            my $y  = $scale->value_to_y( $lv->{price} );
            my $x1 = $scale->index_to_center_x( $lv->{index} );
            $x1 = 0 if $x1 < 0;
            next if $x1 >= $plot_w;

            $canvas->createLine(
                $x1, $y, $plot_w, $y,
                -fill => $color, -dash => [ 2, 3 ], -width => 1, -tags => [TAG] );

            $self->_chip( $canvas, $plot_w - 20, $y, $text,
                -color => $color, -style => 'outline', -place => 'center',
                -placed => $placed );
        }
    }
}

# -----------------------------------------------------------------------------
# Swing Points: marcador triangular pequeno y sobrio (sin texto, no satura).
# Rojo en swing high, verde en swing low (relacion de color por tipo).
# -----------------------------------------------------------------------------
sub _render_swings {
    my ( $self, $canvas, $scale, $src ) = @_;
    my $swings = $src->get_swings or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    for my $sw (@$swings) {
        next if $sw->{index} < $off || $sw->{index} > $off + $vb;
        next unless $scale->value_in_range( $sw->{price} );

        my $x  = $scale->index_to_center_x( $sw->{index} );
        my $up = ( $sw->{kind} eq 'H' );
        my $y  = $scale->value_to_y( $sw->{price} );
        my $color = $up ? C_BSL : C_SSL;
        my $dy = $up ? -7 : 7;

        $canvas->createLine( $x - 3, $y + $dy, $x, $y,
            -fill => $color, -width => 1, -tags => [TAG] );
        $canvas->createLine( $x + 3, $y + $dy, $x, $y,
            -fill => $color, -width => 1, -tags => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# EQH / EQL: linea punteada que conecta ambos pivotes iguales + chip outline.
# -----------------------------------------------------------------------------
sub _render_equals {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $eqs = $src->get_equals or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    for my $e (@$eqs) {
        my $is_high = ( $e->{kind} eq 'EQH' );
        next if $is_high  && !$self->{show_eqh};
        next if !$is_high && !$self->{show_eql};

        next if $e->{i2} < $off || $e->{i1} > $off + $vb;
        next unless $scale->value_in_range( $e->{p1} )
                 || $scale->value_in_range( $e->{p2} );

        my $x1 = $scale->index_to_center_x( $e->{i1} );
        my $x2 = $scale->index_to_center_x( $e->{i2} );
        my $y1 = $scale->value_to_y( $e->{p1} );
        my $y2 = $scale->value_to_y( $e->{p2} );

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill => C_EQ, -width => 1, -dash => [ 4, 2 ], -tags => [TAG] );

        $self->_chip( $canvas, ( $x1 + $x2 ) / 2, ( $y1 + $y2 ) / 2, $e->{kind},
            -color => C_EQ, -style => 'outline',
            -place => ( $is_high ? 'above' : 'below' ), -placed => $placed );
    }
}

# -----------------------------------------------------------------------------
# Eventos Sweep / Grab / Run: marcador en la vela de resolucion + chip solido
# (anti-solape, prioriza los mas recientes).
#
# FIX-LQ2 (v2 -- clustering por cercania, no por indice exacto):
# Una sola racha volatil puede resolver varios niveles HISTORICAMENTE
# DISTINTOS (no duplicados -- verificado con datos reales del
# 2026_06_29.csv) en la misma vela O en un puñado de velas consecutivas.
# Exigir el MISMO indice exacto es fragil: pequenos desfases en como se
# construyen las velas (orden de concatenacion de CSVs, deduplicado por
# timestamp, etc.) pueden mover la resolucion de un nivel una vela para
# adelante o atras sin que eso cambie el hecho de que visualmente caen en
# el mismo punto del grafico. Por eso se agrupan por CERCANIA: mismo
# type+dir Y separados por <= CLUSTER_GAP velas entre resoluciones
# consecutivas -> un solo marcador con contador ("SSL GRAB x4"), anclado a
# la vela MAS RECIENTE del grupo, en vez de N chips sueltos.
# -----------------------------------------------------------------------------
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $start = $#$events - MAX_EVENTS;
    $start = 0 if $start < 0;

    # --- Paso 1: filtrar por toggles/ventana visible ---
    my @visible;
    for ( my $k = $start; $k <= $#$events; $k++ ) {
        my $ev = $events->[$k];
        my $t  = $ev->{type};
        next if $t eq 'SWEEP' && !$self->{show_sweeps};
        next if $t eq 'GRAB'  && !$self->{show_grabs};
        next if $t eq 'RUN'   && !$self->{show_runs};
        next if $ev->{index} < $off || $ev->{index} > $off + $vb;
        push @visible, $ev;
    }
    # get_events() ya viene en orden cronologico de resolucion, pero no lo
    # asumimos: el clustering por cercania depende de recorrerlos ordenados.
    @visible = sort { $a->{index} <=> $b->{index} } @visible;

    # --- Paso 2: clustering por cercania (no por indice exacto) ---
    my @groups;
    for my $ev (@visible) {
        my $g = $groups[-1];
        if (   $g
            && $g->{type} eq $ev->{type}
            && $g->{dir}  eq $ev->{dir}
            && ( $ev->{index} - $g->{index} ) <= CLUSTER_GAP )
        {
            push @{ $g->{prices} }, $ev->{price};
            $g->{index} = $ev->{index} if $ev->{index} > $g->{index};   # ancla al mas reciente
        }
        else {
            push @groups, {
                type => $ev->{type}, dir => $ev->{dir}, label => $ev->{label},
                index => $ev->{index}, prices => [ $ev->{price} ],
            };
        }
    }

    # --- Paso 3: dibujar del mas reciente al mas antiguo (igual que antes) ---
    for my $g ( reverse @groups ) {
        my $up = ( $g->{dir} eq 'up' );

        # Precio representativo: el extremo del grupo (el barrido mas
        # profundo), no un promedio -- asi el marcador queda anclado al
        # nivel que de verdad importa en vez de flotar entre varios.
        my $price = $up ? _min( @{ $g->{prices} } ) : _max( @{ $g->{prices} } );
        next unless $scale->value_in_range($price);

        my $x = $scale->index_to_center_x( $g->{index} );
        my $y = $scale->value_to_y($price);
        my $color =
            ( $g->{type} eq 'GRAB' ) ? C_GRAB
          : ( $g->{type} eq 'RUN' )  ? C_RUN
          : ( $up ? C_BSL : C_SSL );

        my $dy = $up ? -10 : 10;

        $canvas->createLine( $x, $y, $x, $y + $dy,
            -fill => $color, -width => 2, -tags => [TAG] );
        $canvas->createOval( $x - 3, $y - 3, $x + 3, $y + 3,
            -fill => $color, -outline => $color, -tags => [TAG] );

        my $n     = scalar @{ $g->{prices} };
        my $label = $n > 1 ? "$g->{label} x$n" : $g->{label};

        $self->_chip( $canvas, $x, $y + $dy, $label,
            -color => $color, -style => 'solid',
            -place => ( $up ? 'above' : 'below' ), -placed => $placed );
    }
}

sub _min { my $m = shift; for (@_) { $m = $_ if $_ < $m } return $m; }
sub _max { my $m = shift; for (@_) { $m = $_ if $_ > $m } return $m; }

# -----------------------------------------------------------------------------
# _chip: etiqueta tipo TradingView (replica del proyecto de referencia).
#   -style 'solid'  : texto blanco sobre chip de color (eventos).
#   -style 'outline': texto de color sobre chip blanco con borde de color.
#   -place 'above'|'below'|'center' respecto a (cx,cy); -offset separacion.
#   Anti-solape: si choca con una etiqueta ya puesta, la DESPLAZA (no la borra).
#   $placed acumula las cajas [x1,y1,x2,y2] del frame actual.
# -----------------------------------------------------------------------------
sub _chip {
    my ( $self, $canvas, $cx, $cy, $text, %o ) = @_;
    my $color  = $o{-color} // '#363a45';
    my $style  = $o{-style} // 'solid';
    my $place  = $o{-place} // 'above';
    my $off    = defined $o{-offset} ? $o{-offset} : 9;
    my $font   = $o{-font}
              // ( $style eq 'solid' ? 'TkDefaultFont 12 bold' : 'TkDefaultFont 7 bold' );
    my $placed = $o{-placed};
    my $pad    = 2;

    my $ty = $place eq 'below'  ? $cy + $off
           : $place eq 'center' ? $cy
           :                      $cy - $off;

    my $tid = $canvas->createText(
        $cx, $ty, -text => $text, -anchor => 'center', -font => $font,
        -fill => ( $style eq 'solid' ? '#ffffff' : $color ), -tags => [TAG] );
    my @bb = $canvas->bbox($tid);
    return unless @bb;
    my ( $x1, $y1, $x2, $y2 ) = @bb;
    $x1 -= $pad; $x2 += $pad; $y1 -= 1; $y2 += 1;

    if ($placed) {
        my $dir   = $place eq 'below' ? 1 : -1;
        my $h     = ( $y2 - $y1 ) + 2;
        my $tries = 0;
        while ( $tries++ < 6 && _box_hits( [ $x1, $y1, $x2, $y2 ], $placed ) ) {
            my $shift = $dir * $h;
            $_ += $shift for ( $y1, $y2 );
            $canvas->move( $tid, 0, $shift );
        }
        push @$placed, [ $x1, $y1, $x2, $y2 ];
    }

    my $fill = $style eq 'solid' ? $color : '#ffffff';
    my $rid  = $canvas->createRectangle(
        $x1, $y1, $x2, $y2,
        -fill => $fill, -outline => $color, -width => 1, -tags => [TAG] );
    $canvas->lower( $rid, $tid );
    return [ $x1, $y1, $x2, $y2 ];
}

sub _box_hits {
    my ( $b, $list ) = @_;
    for my $o (@$list) {
        next if $b->[2] < $o->[0] || $b->[0] > $o->[2]
             || $b->[3] < $o->[1] || $b->[1] > $o->[3];
        return 1;
    }
    return 0;
}

1;