# =============================================================================
# market.pl
# =============================================================================

use strict;
use warnings;
use lib '.';

use Tk;
use Time::Moment;

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::ChartEngine;
use Market::OverlayManager;
use Market::Overlays::DemoOverlay;

# =============================================================================
# VENTANA
# =============================================================================
my $mw = MainWindow->new;
$mw->title('Chart Test');
$mw->resizable(1, 1);
$mw->configure(-background => '#1c1f2b');

eval { $mw->state('zoomed') };
eval { $mw->attributes('-zoomed', 1) };
$mw->update;

my $WIN_W = $mw->screenwidth;
my $WIN_H = $mw->screenheight;

if ($mw->width < $WIN_W * 0.9) {
    $mw->geometry("${WIN_W}x${WIN_H}+0+0");
    $mw->update;
}

$WIN_W = $mw->width  if $mw->width  > 100;
$WIN_H = $mw->height if $mw->height > 100;

# =============================================================================
# DIMENSIONES
# =============================================================================
my $PRICE_SCALE_W = 90;
my $TF_BAR_H      = 28;
my $ATR_H_MIN     = 60;
my $ATR_H_MAX     = 400;
my $ATR_H         = 140;
my $CANVAS_W      = $WIN_W;

# =============================================================================
# LAYOUT
# =============================================================================
my $tf_frame = $mw->Frame(-background => '#f1f3f6', -height => $TF_BAR_H)
    ->pack(-fill => 'x', -side => 'top');

my $canvas_price = $mw->Canvas(
    -background         => '#ffffff',
    -bd                 => 0,
    -highlightthickness => 0,
)->pack(-fill => 'both', -expand => 1, -side => 'top');

my $sep_frame = $mw->Frame(
    -background => '#c9cdd7',
    -height     => 4,
    -cursor     => 'sb_v_double_arrow',
)->pack(-fill => 'x', -side => 'top');

my $canvas_atr = $mw->Canvas(
    -height             => $ATR_H,
    -background         => '#ffffff',
    -bd                 => 0,
    -highlightthickness => 0,
)->pack(-fill => 'x', -side => 'top');

# =============================================================================
# DATOS
# =============================================================================
print "Cargando datos...\n";
my $market = Market::MarketData->new;

my $csv_path;
for my $cand ('data/2026_03.csv', '2026_03.csv', '../data/2026_03.csv') {
    if (-f $cand) { $csv_path = $cand; last; }
}
die "No se encuentra 2026_03.csv\n" unless $csv_path;

open my $fh, '<', $csv_path or die "Error abriendo CSV '$csv_path': $!\n";
<$fh>;
my $count = 0;
while (<$fh>) {
    chomp;
    my ($time_str, $open, $high, $low, $close, $volume) = split /,/;
    next unless defined $close && $close ne '';
    my $tm;
    eval { $tm = Time::Moment->from_string($time_str) };
    next if $@;
    $market->add_candle({
        time   => $time_str,
        ts     => $tm->epoch,
        open   => $open  + 0,
        high   => $high  + 0,
        low    => $low   + 0,
        close  => $close + 0,
        volume => $volume + 0,
    });
    $count++;
}
close $fh;

printf "Cargadas %d velas de 1m\n", $count;
$market->build_timeframes;
printf "5m: %d  |  15m: %d\n",
    scalar @{ $market->get_data->{'5m'} },
    scalar @{ $market->get_data->{'15m'} };

# =============================================================================
# INDICADORES
# =============================================================================
my $ind_manager = Market::IndicatorManager->new;
$ind_manager->register('atr', Market::Indicators::ATR->new(14));
print "Calculando ATR(14)...\n";
$ind_manager->rebuild_all($market);
printf "ATR listo: %d valores\n", scalar @{ $ind_manager->get('atr') };

# =============================================================================
# OVERLAYS — gestor + overlay de validacion (Etapa 2, Fase 2)
# El overlay 'demo' es temporal: solo confirma que la arquitectura de
# Overlays funciona (registro, render sincronizado con scroll/zoom,
# toggle de visibilidad) antes de implementar Liquidity.pm en la Etapa 8.
# Se debe quitar (o sustituir su registro por el de Liquidity) mas adelante.
# =============================================================================
my $overlay_mgr = Market::OverlayManager->new;
$overlay_mgr->register('demo', Market::Overlays::DemoOverlay->new(
    price        => $market->last_candle->{close},  # nivel de precio = ultimo close real del CSV
    marker_index => $market->size - 50,              # cae dentro de la ventana inicial (ultimas 120 velas)
));

# =============================================================================
# PANELES Y MOTOR
# =============================================================================
my $price_panel = Market::Panels::PricePanel->new(
    canvas        => $canvas_price,
    price_scale_w => $PRICE_SCALE_W,
);
my $atr_panel = Market::Panels::ATRPanel->new(
    canvas        => $canvas_atr,
    price_scale_w => $PRICE_SCALE_W,
);

my $engine = Market::ChartEngine->new(
    market         => $market,
    indicators     => $ind_manager,
    overlays       => $overlay_mgr,
    canvas_price   => $canvas_price,
    canvas_atr     => $canvas_atr,
    price_panel    => $price_panel,
    atr_panel      => $atr_panel,
    canvas_w       => $CANVAS_W,
    canvas_price_h => 0,
    canvas_atr_h   => $ATR_H,
);

# =============================================================================
# TOOLBAR — se crea ANTES de registrar callbacks para que los botones existan
# =============================================================================
my %bs = (
    -background       => '#f1f3f6',
    -foreground       => '#363a45',
    -activebackground => '#dde0e8',
    -activeforeground => '#131722',
    -relief           => 'flat',
    -bd               => 0,
    -font             => 'TkDefaultFont 9',
    -padx             => 5,
    -pady             => 3,
);

$tf_frame->Label(%bs, -text => 'Zoom')
    ->pack(-side => 'left', -padx => 6, -pady => 2);

$tf_frame->Button(%bs, -text => '+',
    -command => sub { $engine->_horizontal_zoom(-1, 0) })
    ->pack(-side => 'left', -padx => 1, -pady => 2);
$tf_frame->Button(%bs, -text => '-',
    -command => sub { $engine->_horizontal_zoom(1, 0) })
    ->pack(-side => 'left', -padx => 1, -pady => 2);

$tf_frame->Frame(-background => '#c9cdd7', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

# --- Checkbutton de visibilidad de overlays (Etapa 2) ---
my $demo_overlay_visible = 1;
$tf_frame->Checkbutton(
    -text       => 'Demo Overlay',
    -variable   => \$demo_overlay_visible,
    -onvalue    => 1,
    -offvalue   => 0,
    -background => '#f1f3f6',
    -font       => 'TkDefaultFont 9',
    -command    => sub {
        $overlay_mgr->set_visible('demo', $demo_overlay_visible);
        $engine->request_render;
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$tf_frame->Frame(-background => '#c9cdd7', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

# --- Boton modo precio ---
my $mode_btn;
$mode_btn = $tf_frame->Button(%bs,
    -text       => 'P:Auto',
    -foreground => '#26a69a',
    -font       => 'TkDefaultFont 9 bold',
    -command    => sub {
        my $is_free = $engine->toggle_free_mode_price;
        # El callback se encarga de actualizar el boton
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

# --- Boton modo ATR ---
my $mode_btn_atr;
$mode_btn_atr = $tf_frame->Button(%bs,
    -text       => 'ATR:Auto',
    -foreground => '#26a69a',
    -font       => 'TkDefaultFont 9 bold',
    -command    => sub {
        my $is_free = $engine->toggle_free_mode_atr;
        # El callback se encarga de actualizar el boton
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$tf_frame->Frame(-background => '#c9cdd7', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

# =============================================================================
# CALLBACKS DE MODO — sincronizan botones con estado interno del engine
# Cualquier cambio de modo (boton, regleta, dbl-clic) actualiza el boton.
# =============================================================================
$engine->set_mode_callbacks(
    sub {   # callback precio
        my ($is_free) = @_;
        $mode_btn->configure(
            -text       => $is_free ? 'P:Manual' : 'P:Auto',
            -foreground => $is_free ? '#ef5350'  : '#26a69a',
        );
    },
    sub {   # callback ATR
        my ($is_free) = @_;
        $mode_btn_atr->configure(
            -text       => $is_free ? 'ATR:Manual' : 'ATR:Auto',
            -foreground => $is_free ? '#ef5350'    : '#26a69a',
        );
    },
);

# =============================================================================
# TEMPORALIDADES
# =============================================================================
my $active_tf = '1m';
my $tf_lbl = $tf_frame->Label(%bs,
    -text       => '1m',
    -foreground => '#2962ff',
    -font       => 'TkDefaultFont 9 bold',
)->pack(-side => 'left', -padx => 4, -pady => 2);

my %tf_btns;
for my $tf (qw(1m 5m 15m 1h 2h 4h D W)) {
    my $btn = $tf_frame->Button(%bs,
        -text    => $tf,
        -font    => 'TkDefaultFont 9 bold',
        -command => sub {
            return if $active_tf eq $tf;
            $active_tf = $tf;
            $tf_lbl->configure(-text => $tf);
            for my $k (keys %tf_btns) {
                $tf_btns{$k}->configure(
                    -foreground => ($k eq $tf ? '#2962ff' : '#363a45')
                );
            }
            $engine->set_timeframe($tf);

            # Resetear botones de modo a Auto
            $mode_btn->configure(
                -text       => 'P:Auto',
                -foreground => '#26a69a',
            );
            $mode_btn_atr->configure(
                -text       => 'ATR:Auto',
                -foreground => '#26a69a',
            );
        },
    )->pack(-side => 'left', -padx => 1, -pady => 2);
    $tf_btns{$tf} = $btn;
}
$tf_btns{'1m'}->configure(-foreground => '#2962ff');

$tf_frame->Label(%bs,
    -text       => 'Rueda: zoom  |  Ctrl+Rueda: ancla mouse  |  Shift+Rueda: zoom V  |  Drag regleta: zoom V  |  Dbl-regleta: auto  |  Drag sep: resize ATR',
    -foreground => '#787b86',
    -font       => 'TkDefaultFont 7',
)->pack(-side => 'right', -padx => 10);

# =============================================================================
# DRAG DEL SEPARADOR ATR
# =============================================================================
{
    my $drag_y_start = undef;
    my $drag_atr_h   = undef;

    $sep_frame->bind('<ButtonPress-1>', sub {
        $drag_y_start = $_[0]->XEvent->Y;
        $drag_atr_h   = $canvas_atr->height;
    });

    $sep_frame->bind('<B1-Motion>', sub {
        return unless defined $drag_y_start;
        my $dy    = $drag_y_start - $_[0]->XEvent->Y;
        my $new_h = $drag_atr_h + $dy;
        $new_h = $ATR_H_MIN if $new_h < $ATR_H_MIN;
        $new_h = $ATR_H_MAX if $new_h > $ATR_H_MAX;

        $canvas_atr->configure(-height => $new_h);
        $engine->resize_panels(
            $canvas_price->width,
            $canvas_price->height - ($new_h - $drag_atr_h),
            $new_h,
        );
    });

    $sep_frame->bind('<ButtonRelease-1>', sub {
        $drag_y_start = undef;
        $drag_atr_h   = undef;
    });

    $sep_frame->bind('<Double-Button-1>', sub {
        $canvas_atr->configure(-height => 140);
        $mw->update;
        $engine->resize_panels(
            $canvas_price->width,
            $canvas_price->height,
            140,
        );
    });
}

# =============================================================================
# PRIMER RENDER
# =============================================================================
$engine->reset_view;
$mw->after(80, sub { $engine->render });
MainLoop;