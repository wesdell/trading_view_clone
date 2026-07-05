package Market::Overlays::LabelPlacer;

# =============================================================================
# Market::Overlays::LabelPlacer
#
# Sistema de anti-solapamiento visual de etiquetas (chips) para el grafico.
# Los overlays NO dibujan sus etiquetas directamente: las ENCOLAN aqui con
# add(). ChartEngine crea un placer por frame, lo siembra con las cajas de las
# velas visibles (obstaculos), lo pasa a los overlays durante el render y al
# final llama flush(), que coloca todas las etiquetas evitando:
#   - cuerpos y mechas de las velas,
#   - otras etiquetas ya colocadas.
#
# Estrategia de colocacion por etiqueta (spec 8):
#   1. medir su bounding box real en pantalla,
#   2. probar slots verticales sucesivos hacia su lado preferido (above/below),
#   3. si no hay hueco, probar un pequeno desplazamiento horizontal,
#   4. si queda lejos del ancla, dibujar una linea guia (leader line),
#   5. si aun no cabe y es de baja prioridad (hideable), ocultarla.
#
# Las etiquetas se colocan en orden de PRIORIDAD (1 = mayor). Asi las mas
# importantes (OB, BOS/CHoCH) reclaman su espacio primero y las secundarias
# (HH/HL, EQH/EQL, FVG) se acomodan alrededor o se ocultan.
# =============================================================================

use strict;
use warnings;

use constant {
    BASE_OFFSET => 10,   # px del ancla al primer slot
    SLOT_STEP   => 15,   # px entre slots verticales
    MAX_SLOTS   => 7,    # slots verticales a probar por lado
    NUDGE_PX    => 14,   # desplazamiento horizontal de rescate
    LEADER_MIN  => 20,   # si el chip queda a mas de esto del ancla -> linea guia
    PAD         => 2,
};

sub new {
    my ( $class, %args ) = @_;
    bless {
        obstacles => $args{obstacles} || [],   # [ [x1,y1,x2,y2], ... ] (velas)
        plot_w    => $args{plot_w}    || 1e9,
        plot_h    => $args{plot_h}    || 1e9,
        items     => [],
        _shown    => 0,
        _hidden   => 0,
    }, $class;
}

# -----------------------------------------------------------------------------
# add: encola una etiqueta. Opciones:
#   x, y        -> ancla (px) sobre la que se quiere la etiqueta
#   text        -> texto
#   color       -> color del chip
#   style       -> 'solid' (texto blanco sobre color) | 'outline' (texto color)
#   side        -> 'above' | 'below' | 'center' (lado preferido)
#   priority    -> 1..7 (1 = mayor; se colocan primero)
#   hideable    -> 1 si puede ocultarse cuando no hay espacio
#   font        -> fuente Tk
# -----------------------------------------------------------------------------
sub add {
    my ( $self, %o ) = @_;
    push @{ $self->{items} }, \%o;
}

sub counts { return ( $_[0]->{_shown}, $_[0]->{_hidden} ); }

# -----------------------------------------------------------------------------
# flush: coloca y dibuja todas las etiquetas encoladas.
# -----------------------------------------------------------------------------
sub flush {
    my ( $self, $canvas, $tag ) = @_;
    $tag ||= 'labels';

    my @placed = @{ $self->{obstacles} };   # arranca con las velas
    my @items =
        sort { ( $a->{priority} // 9 ) <=> ( $b->{priority} // 9 )
               or ( $a->{x} // 0 ) <=> ( $b->{x} // 0 ) }
        @{ $self->{items} };

    for my $L (@items) {
        $self->_place_one( $canvas, $tag, $L, \@placed );
    }
    return ( $self->{_shown}, $self->{_hidden} );
}

# -----------------------------------------------------------------------------
# _place_one (privado)
# -----------------------------------------------------------------------------
sub _place_one {
    my ( $self, $canvas, $tag, $L, $placed ) = @_;

    my $style = $L->{style} // 'solid';
    my $font  = $L->{font}
        // ( $style eq 'solid' ? 'TkDefaultFont 8 bold' : 'TkDefaultFont 7 bold' );

    # 1) Medir el texto creandolo en una posicion temporal.
    my $tid = $canvas->createText(
        $L->{x}, $L->{y},
        -text   => $L->{text},
        -anchor => 'center',
        -font   => $font,
        -fill   => ( $style eq 'solid' ? '#ffffff' : ( $L->{color} // '#363a45' ) ),
        -tags   => [$tag],
    );
    my @bb = $canvas->bbox($tid);
    unless (@bb) { $canvas->delete($tid); return; }
    my $w = ( $bb[2] - $bb[0] ) / 2 + PAD;   # semiancho
    my $h = ( $bb[3] - $bb[1] ) / 2 + 1;     # semialto

    my $side = $L->{side} // 'above';
    my ( $ax, $ay ) = ( $L->{x}, $L->{y} );

    # 2) Buscar una posicion (cx,cy) del CENTRO del chip que no colisione.
    my ( $cx, $cy, $found ) = $self->_find_slot( $ax, $ay, $w, $h, $side, $placed );

    if ( !$found ) {
        if ( $L->{hideable} ) { $canvas->delete($tid); $self->{_hidden}++; return; }
        # No ocultable: colocar en el mejor esfuerzo (primer slot).
        ( $cx, $cy ) = $self->_first_slot( $ax, $ay, $side );
    }

    # 3) Mover el texto al centro elegido.
    $canvas->move( $tid, $cx - $ax, $cy - $ay );
    my $box = [ $cx - $w, $cy - $h, $cx + $w, $cy + $h ];

    # 4) Linea guia si el chip quedo lejos del ancla.
    my $dist = abs( $cy - $ay );
    if ( $dist > LEADER_MIN ) {
        my $edge_y = ( $cy > $ay ) ? ( $cy - $h ) : ( $cy + $h );
        $canvas->createLine(
            $ax, $ay, $cx, $edge_y,
            -fill => ( $L->{color} // '#888888' ), -width => 1, -tags => [$tag],
        );
    }

    # 5) Fondo del chip + texto encima.
    my $fill = ( $style eq 'solid' ) ? ( $L->{color} // '#363a45' ) : '#ffffff';
    my $rid = $canvas->createRectangle(
        @$box,
        -fill => $fill, -outline => ( $L->{color} // '#363a45' ), -width => 1,
        -tags => [$tag],
    );
    $canvas->lower( $rid, $tid );

    push @$placed, $box;
    $self->{_shown}++;
    return 1;
}

# _first_slot: centro del primer slot para un lado dado.
sub _first_slot {
    my ( $self, $ax, $ay, $side ) = @_;
    return ( $ax, $ay ) if $side eq 'center';
    my $dir = ( $side eq 'below' ) ? 1 : -1;
    return ( $ax, $ay + $dir * BASE_OFFSET );
}

# _find_slot: prueba slots verticales y, si falla, un desplazamiento horizontal.
sub _find_slot {
    my ( $self, $ax, $ay, $w, $h, $side, $placed ) = @_;

    my @dirs = $side eq 'center' ? ( -1, 1 )
             : $side eq 'below'  ? ( 1, -1 )
             :                     ( -1, 1 );

    for my $nudge ( 0, NUDGE_PX, -NUDGE_PX ) {
        my $cx = $ax + $nudge;
        for my $dir (@dirs) {
            for my $slot ( 0 .. MAX_SLOTS - 1 ) {
                my $cy = $ay + $dir * ( BASE_OFFSET + $slot * SLOT_STEP );
                $cy = $ay if $side eq 'center' && $slot == 0 && $dir == $dirs[0];
                my $box = [ $cx - $w, $cy - $h, $cx + $w, $cy + $h ];
                next if $box->[1] < 0 || $box->[3] > $self->{plot_h};
                return ( $cx, $cy, 1 ) unless _hits( $box, $placed );
            }
        }
    }
    return ( $ax, $ay, 0 );
}

sub _hits {
    my ( $b, $list ) = @_;
    for my $o (@$list) {
        next if $b->[2] < $o->[0] || $b->[0] > $o->[2]
             || $b->[3] < $o->[1] || $b->[1] > $o->[3];
        return 1;
    }
    return 0;
}

1;
