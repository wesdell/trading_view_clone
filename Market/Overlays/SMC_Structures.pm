package Market::Overlays::SMC_Structures;

# =============================================================================
# Market::Overlays::SMC_Structures   (Tabla 1 del PDF)
#
# Capa visual de las estructuras SMC ya calculadas por
# Indicators/SMC_Structures.pm: zonas FVG con desvanecimiento progresivo y
# lineas BOS / CHoCH con etiquetas ubicadas en el tiempo. NO calcula nada.
#
# Estilo de etiquetas: igual que el indicador "SMC Structures and FVG" de
# referencia (helper _chip):
#   - solid   : texto blanco sobre chip de color   -> eventos (BOS / CHoCH).
#   - outline : texto de color sobre chip blanco    -> etiqueta de la zona FVG.
#   El chip se ancla a la coordenada X/precio reales (index_to_center_x /
#   value_to_y), con anti-solape que DESPLAZA la etiqueta verticalmente (no la
#   borra), redibujado cada frame -> estable en replay/zoom/desplazamiento.
#
#   BOS   : linea horizontal SOLIDA en el nivel roto, color direccional
#           (verde alcista / rojo bajista), chip centrado sobre la linea.
#   CHoCH : linea PUNTEADA violeta, chip centrado.
#   FVG   : caja semitransparente que se desvanece con la edad (interpolacion
#           de color hacia el fondo).
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Sub-toggles independientes: show_fvg / show_bos / show_choch.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_smc';

use constant {
    C_UP    => '#26a69a',   # BOS alcista / FVG alcista (verde)
    C_DOWN  => '#ef5350',   # BOS bajista / FVG bajista (rojo)
    C_CHOCH => '#ab47bc',   # CHoCH (violeta)
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source     => $args{source},
        max_age    => $args{max_age} // 50,
        show_fvg   => $args{show_fvg}   // 1,
        show_bos   => $args{show_bos}   // 1,
        show_choch => $args{show_choch} // 1,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# -----------------------------------------------------------------------------
# render: se auto-limpia con su tag y dibuja solo lo visible.
# El FVG va primero (al fondo); las lineas/chips de BOS/CHoCH encima.
# -----------------------------------------------------------------------------
sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    my @placed;   # cajas [x1,y1,x2,y2] de etiquetas ya colocadas (anti-solape)
    $self->_render_fvgs( $canvas, $scale, $src, \@placed ) if $self->{show_fvg};
    $self->_render_events( $canvas, $scale, $src, \@placed )
        if $self->{show_bos} || $self->{show_choch};
}

# -----------------------------------------------------------------------------
# FVG: caja semitransparente tenue con desvanecimiento por edad (interpolacion
# de color hacia el fondo blanco). La edad usa processed_last (replay-aware).
# -----------------------------------------------------------------------------
sub _render_fvgs {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $fvgs = $src->get_fvgs or return;
    my $last_known = $src->processed_last;
    my $max_age    = $self->{max_age};

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    for my $f (@$fvgs) {
        next if $f->{state} eq 'expired';

        my $age = $last_known - $f->{created};
        next if $age > $max_age;

        my $right_idx = ( $f->{state} eq 'mitigated' && defined $f->{mitig_at} )
            ? $f->{mitig_at}
            : $f->{created} + $max_age;
        $right_idx = $last_known if $right_idx > $last_known;

        next if $right_idx      < $off;
        next if $f->{idx_start} > $off + $vb;
        next unless $scale->value_in_range( $f->{top} )
                 || $scale->value_in_range( $f->{bottom} )
                 || ( $f->{bottom} < $scale->{min_val}
                   && $f->{top}    > $scale->{max_val} );

        my $fresh = 1 - ( $age / $max_age );
        $fresh = 0 if $fresh < 0;

        my $base    = ( $f->{dir} eq 'bull' ) ? C_UP : C_DOWN;
        my $fill_op = 0.08 + 0.12 * $fresh;          # 0.08 .. 0.20
        $fill_op *= 0.55 if $f->{state} eq 'mitigated';
        my $fill = _mix( $base, $fill_op );
        my $line = _mix( $base, 0.30 + 0.30 * $fresh );

        my $x1 = $scale->index_to_center_x( $f->{idx_start} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $f->{top} );
        my $yb = $scale->value_to_y( $f->{bottom} );

        $canvas->createRectangle(
            $x1, $yt, $x2, $yb,
            -fill    => $fill,
            -outline => $line,
            -width   => 1,
            -tags    => [TAG],
        );

        # Etiqueta "FVG" (chip outline pequeno) centrada, solo en zonas con
        # altura util y aun frescas, para no saturar.
        if ( ( $yb - $yt ) >= 12 && $age <= int( $max_age * 0.5 ) ) {
            my $tx = ( $x1 + $x2 ) / 2;
            $tx = 24 if $tx < 24;
            $self->_chip( $canvas, $tx, ( $yt + $yb ) / 2, 'FVG',
                -color => $base, -style => 'outline', -place => 'center',
                -font => 'TkDefaultFont 6 bold', -placed => $placed );
        }
    }
}

# -----------------------------------------------------------------------------
# BOS / CHoCH: linea horizontal en el nivel roto, del pivote de origen a la
# vela de ruptura, con chip SOLIDO centrado sobre la linea.
# -----------------------------------------------------------------------------
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events or return;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    # De mas reciente a mas antiguo: si dos chips chocan, gana el mas nuevo.
    for ( my $k = $#$events ; $k >= 0 ; $k-- ) {
        my $e = $events->[$k];
        my $is_choch = ( $e->{type} eq 'CHoCH' );
        next if !$is_choch && !$self->{show_bos};
        next if  $is_choch && !$self->{show_choch};

        my $bi = $e->{index};
        next if $bi < $off || $bi > $off + $vb;
        next unless $scale->value_in_range( $e->{price} );

        my $oi = defined $e->{origin} ? $e->{origin} : $bi - 6;
        my $x1 = $scale->index_to_center_x($oi);
        my $x2 = $scale->index_to_center_x($bi);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $y     = $scale->value_to_y( $e->{price} );
        my $color = $is_choch ? C_CHOCH : ( $e->{dir} eq 'up' ? C_UP : C_DOWN );

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill => $color, -width => 1,
            ( $is_choch ? ( -dash => [ 5, 3 ] ) : () ),
            -tags => [TAG] );

        my $up = ( ( $e->{dir} || 'up' ) eq 'up' );
        $self->_chip( $canvas, ( $x1 + $x2 ) / 2, $y, $e->{label},
            -color => $color, -style => 'solid',
            -place => ( $up ? 'above' : 'below' ), -placed => $placed );
    }
}

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

# -----------------------------------------------------------------------------
# _mix: mezcla un color hex con el fondo blanco. $op=1 -> color pleno;
# $op=0 -> blanco. Simula opacidad (Tk Canvas no tiene canal alfa nativo).
# -----------------------------------------------------------------------------
sub _mix {
    my ( $hex, $op ) = @_;
    $op = 0 if $op < 0;
    $op = 1 if $op > 1;
    my ( $r, $g, $b ) = ( hex( substr( $hex, 1, 2 ) ),
                          hex( substr( $hex, 3, 2 ) ),
                          hex( substr( $hex, 5, 2 ) ) );
    my $f = 1 - $op;
    $r = int( $r + ( 255 - $r ) * $f );
    $g = int( $g + ( 255 - $g ) * $f );
    $b = int( $b + ( 255 - $b ) * $f );
    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

1;
