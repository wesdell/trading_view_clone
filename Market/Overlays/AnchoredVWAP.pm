package Market::Overlays::AnchoredVWAP;

# =============================================================================
# Market::Overlays::AnchoredVWAP  (2a fase)
# Dibuja las lineas VWAP ancladas ya calculadas por Indicators::AnchoredVWAP.
# La formula vive en el indicador (vwap_line); aqui solo se pide el tramo VISIBLE
# y se traza. Un color por tipo de ancla; sub-toggles independientes. No calcula.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_avwap';
my %COLOR = (
    session => '#26a69a',   # inicio de sesion (ETH)
    open    => '#42a5f5',   # apertura oficial (RTH)
    BOS     => '#2962ff',   # BOS confirmado
    CHoCH   => '#ab47bc',   # CHoCH confirmado
    POC     => '#ff9800',   # POC del Volume Profile
);
my %FLAGKEY = (
    session => 'show_session', open => 'show_open', BOS => 'show_bos',
    CHoCH   => 'show_choch',   POC  => 'show_poc',
);

sub new {
    my ($class, %args) = @_;
    my $self = {
        source       => $args{source},
        show_session => $args{show_session} // 1,
        show_open    => $args{show_open}    // 1,
        show_bos     => $args{show_bos}     // 1,
        show_choch   => $args{show_choch}   // 1,
        show_poc     => $args{show_poc}     // 1,
        show_inactive=> $args{show_inactive}// 0,
        _plot_w      => undef,
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

    # IDEMPOTENCIA (contrato de OverlayManager, igual que SMC_Structures/Liquidity):
    # borrar los items del frame anterior por el tag general ANTES de redibujar.
    # Sin esto, cada zoom/pan/scroll/Replay acumulaba lineas VWAP encima de las
    # previas (duplicados). NO toca el estado matematico (las anclas viven en el
    # indicador); solo limpia el Canvas.
    $canvas->delete(TAG);

    # rango visible de indices
    my $off = $scale->{offset}; my $vb = $scale->{visible_bars};
    my $vfrom = int($off);        $vfrom = 0 if $vfrom < 0;
    my $vto   = int($off) + $vb + 1;

    for my $a (@{ $src->get_anchors }) {
        next if $a->{state} ne 'active' && !$self->{show_inactive};
        my $fk = $FLAGKEY{ $a->{type} } or next;
        next unless $self->{$fk};

        my $line = $src->vwap_line($a, $vfrom, $vto);
        next unless $line && @$line >= 2;
        my $col  = $COLOR{ $a->{type} } // '#888888';
        my $dash = ($a->{state} eq 'active') ? undef : [3,3];
        my $wdt  = ($a->{state} eq 'active') ? 2 : 1;

        # UNA polilinea por tramo continuo (menos objetos Canvas que N segmentos).
        my @co;
        my $flush = sub {
            if (@co >= 4) {
                $canvas->createLine(@co, -fill=>$col, -width=>$wdt,
                    ($dash ? (-dash=>$dash) : ()), -tags=>[TAG]);
            }
            @co = ();
        };
        for my $p (@$line) {
            if (!defined $p->{value}) { $flush->(); next; }
            my $x = $scale->index_to_center_x($p->{idx});
            if ($x < -0.5 || $x > $plot_w + 0.5) { $flush->(); next; }   # solo rango visible
            push @co, $x, $scale->value_to_y($p->{value});
        }
        $flush->();

        # etiqueta en el extremo derecho visible del ancla
        my $liter = $line->[-1];
        if (defined $liter->{value} && $scale->value_in_range($liter->{value})) {
            my $x = $scale->index_to_center_x($liter->{idx});
            $x = $plot_w if $x > $plot_w;
            my $y = $scale->value_to_y($liter->{value});
            $self->_chip($canvas, $x, $y, 'VWAP:'.$a->{type}, $col);
        }
    }
}

sub _chip {
    my ($self, $canvas, $x, $y, $txt, $col) = @_;
    my $tx = $x - 4; $tx = ($self->{_plot_w} - 4) if defined $self->{_plot_w} && $tx > $self->{_plot_w} - 4;
    $tx = 30 if $tx < 30;
    $canvas->createText($tx, $y, -text=>$txt, -fill=>$col, -anchor=>'e',
        -font=>'TkDefaultFont 6 bold', -tags=>[TAG]);
}

1;
