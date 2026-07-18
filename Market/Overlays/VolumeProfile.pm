package Market::Overlays::VolumeProfile;

# =============================================================================
# Market::Overlays::VolumeProfile  (2a fase)
# Dibuja lo YA calculado por Indicators::VolumeProfile. POC/VAH/VAL estan a
# PRECIOS fijos (calculados sobre toda la data del segmento): NO cambian con
# zoom/scroll; solo su extension en X se recorta al rango visible. Sub-toggles
# independientes. No calcula nada.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_volumeprofile';
use constant {
    C_POC  => '#ff9800',
    C_VA   => '#7e57c2',
    C_HIST => '#90a4ae',
    C_ANC  => '#607d8b',
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        source     => $args{source},
        show_poc   => $args{show_poc}   // 1,
        show_va    => $args{show_va}    // 1,
        show_hist  => $args{show_hist}  // 1,
        show_anchor=> $args{show_anchor}// 1,
        hist_max_w => $args{hist_max_w} // 90,   # ancho maximo del histograma (px)
        _plot_w    => undef,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ($self, $flag, $val) = @_;
    $self->{$flag} = $val ? 1 : 0 if exists $self->{$flag};
}

sub render {
    my ($self, $canvas, $scale, $placer) = @_;
    my $src = $self->{source} or return;
    $self->{_plot_w} = $scale->_plot_w;
    my $plot_w = $scale->_plot_w;
    my $last   = $self->_last_index($src);

    # IDEMPOTENCIA (contrato de OverlayManager, igual que SMC_Structures/Liquidity/
    # AnchoredVWAP): borrar los items del frame anterior por el tag general ANTES de
    # redibujar. Sin esto, cada zoom/pan/scroll/Replay acumulaba histogramas/lineas
    # POC/VAH/VAL encima de las previas. NO toca el estado matematico (los perfiles
    # viven en el indicador); solo limpia el Canvas.
    $canvas->delete(TAG);

    for my $p (@{ $src->get_profiles }) {
        next if $p->{incomplete};
        next unless defined $p->{start_idx};
        my $ei = defined $p->{end_idx} ? $p->{end_idx} : $last;
        $ei = $last if $ei > $last;
        # descartar perfiles totalmente fuera del rango visible (optimizacion de render)
        my $xa = $scale->index_to_center_x($p->{start_idx});
        my $xe = $scale->index_to_center_x($ei);
        next if $xe < 0 || $xa > $plot_w;

        my ($x1,$x2) = ($xa, $xe);
        $x1 = 0 if $x1 < 0; $x2 = $plot_w if $x2 > $plot_w;

        # --- histograma (barras horizontales por bin), anclado en x_end (lado
        #     DERECHO del perfil, donde van los chips POC/VAH/VAL) y creciendo
        #     hacia la IZQUIERDA (estilo TradingView) ---
        if ($self->{show_hist} && $p->{bins}) {
            my $maxb = 0; $maxb = $_ > $maxb ? $_ : $maxb for @{ $p->{bins} };
            if ($maxb > 0) {
                my $bx = ($x2 > $plot_w ? $plot_w : $x2);   # ancla derecha
                my $nb = $p->{nbins};
                for my $b (0 .. $nb-1) {
                    my $v = $p->{bins}[$b]; next if $v <= 0;
                    my $ylow  = $p->{price_min} + $b     * $p->{binsize};
                    my $yhigh = $p->{price_min} + ($b+1) * $p->{binsize};
                    next unless $scale->value_in_range($ylow) || $scale->value_in_range($yhigh);
                    my $yt = $scale->value_to_y($yhigh);
                    my $yb = $scale->value_to_y($ylow);
                    my $w  = $self->{hist_max_w} * ($v / $maxb);
                    my $col = ($b == $p->{poc_bin}) ? C_POC : C_HIST;
                    $canvas->createRectangle($bx - $w, $yt, $bx, $yb,
                        -fill => _mix($col, 0.35), -outline => '', -tags => [TAG]);
                }
            }
        }

        # --- lineas POC / VAH / VAL a precio fijo (invariantes a zoom) ---
        if ($self->{show_poc} && defined $p->{poc_price} && $scale->value_in_range($p->{poc_price})) {
            my $y = $scale->value_to_y($p->{poc_price});
            $canvas->createLine($x1, $y, $x2, $y, -fill=>C_POC, -width=>2, -tags=>[TAG]);
            $self->_chip($canvas, $x2, $y, 'POC', C_POC);
        }
        if ($self->{show_va}) {
            for my $lv (['VAH',$p->{vah}], ['VAL',$p->{val}]) {
                my ($lab,$price) = @$lv;
                next unless defined $price && $scale->value_in_range($price);
                my $y = $scale->value_to_y($price);
                $canvas->createLine($x1, $y, $x2, $y,
                    -fill=>C_VA, -width=>1, -dash=>[4,3], -tags=>[TAG]);
                $self->_chip($canvas, $x2, $y, $lab, C_VA);
            }
        }

        # --- ancla (vertical en el inicio del perfil) ---
        if ($self->{show_anchor} && $xa >= 0 && $xa <= $plot_w) {
            $canvas->createLine($xa, 0, $xa, $scale->{canvas_h} // 600,
                -fill=>C_ANC, -width=>1, -dash=>[2,4], -tags=>[TAG]);
        }
    }
}

sub _chip {
    my ($self, $canvas, $x, $y, $txt, $col) = @_;
    my $tx = $x - 16; $tx = 16 if $tx < 16;
    $tx = ($self->{_plot_w} - 4) if $tx > ($self->{_plot_w} // 1e9);
    $canvas->createText($tx, $y, -text=>$txt, -fill=>$col, -anchor=>'e',
        -font=>'TkDefaultFont 6 bold', -tags=>[TAG]);
}

sub _last_index {
    my ($self, $src) = @_;
    my $md = $src->get_market_data;
    return $md ? $md->last_index : 0;
}

sub _mix {
    my ($hex, $op) = @_;
    my ($r,$g,$b) = map { hex } ($hex =~ /^#(..)(..)(..)$/);
    $r = int($r*$op + 255*(1-$op)); $g = int($g*$op + 255*(1-$op)); $b = int($b*$op + 255*(1-$op));
    return sprintf('#%02x%02x%02x', $r, $g, $b);
}

1;
