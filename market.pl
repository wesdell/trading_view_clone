# ==============================================================================
# market.pl
# Punto de entrada del sistema de visualizacion de datos de mercado.
# Clon funcional de TradingView usando Perl/Tk.
# ==============================================================================

use strict;
use warnings;

use lib '/home/wesdell/Documentos/trading_view_clone';

use POSIX qw(mktime);
use Tk;
use Tk::Canvas;

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::ChartEngine;

# ------------------------------------------------------------------------------
# CONFIGURACION GENERAL
# ------------------------------------------------------------------------------

my $CANVAS_W     = 1400;
my $PRICE_H      = 450;
my $ATR_H        = 150;
my $SCALE_W      = 75;
my $VISIBLE_BARS = 200;
my $INIT_TF      = 1;

my $CSV_FILE = '2026_03.csv';

# ------------------------------------------------------------------------------
# 1. LECTURA CSV
# ------------------------------------------------------------------------------

print "Cargando datos desde: $CSV_FILE\n";

my $market = Market::MarketData->new();

load_csv($CSV_FILE, $market);

printf "Velas 1m cargadas: %d\n", $market->size();

# ------------------------------------------------------------------------------
# 2. BUILD TIMEFRAMES
# ------------------------------------------------------------------------------

print "Construyendo temporalidades 5m y 15m...\n";

$market->build_timeframes();

$market->set_timeframe($INIT_TF);

# ------------------------------------------------------------------------------
# 3. INDICADORES
# ------------------------------------------------------------------------------

print "Calculando ATR(14)...\n";

my $indicators =
    Market::IndicatorManager->new();

$indicators->register(
    'ATR',
    Market::Indicators::ATR->new(14)
);

my $n1m = $market->size();

for (my $i = 0; $i < $n1m; $i++) {

    my $c =
        $market->get_candle($i);

    my $fake =
        bless { _c => $c }, '_FakeMD';

    $indicators->update_last($fake);
}

printf(
    "ATR calculado: %d valores\n",
    scalar @{ $indicators->get('ATR') }
);

# ------------------------------------------------------------------------------
# 4. VENTANA PRINCIPAL
# ------------------------------------------------------------------------------

print "Iniciando interfaz grafica...\n";

my $mw = MainWindow->new();

$mw->title(
    'Market Chart | 1m | NQ Futuros CME - Abril 2026'
);

$mw->configure(
    -background => '#ffffff'
);

$mw->resizable(1, 1);

$mw->geometry(
    "${CANVAS_W}x" . ($PRICE_H + $ATR_H + 36)
);

# ------------------------------------------------------------------------------
# FRAME PRINCIPAL
# ------------------------------------------------------------------------------

my $main_frame = $mw->Frame(
    -background => '#ffffff'
)->pack(
    -fill   => 'both',
    -expand => 1
);

# ------------------------------------------------------------------------------
# TOOLBAR
# ------------------------------------------------------------------------------

my $toolbar = $main_frame->Frame(
    -background => '#f8fafc',
    -height     => 30,
)->pack(
    -side => 'top',
    -fill => 'x'
);

# ------------------------------------------------------------------------------
# BOTONES TIMEFRAME
# ------------------------------------------------------------------------------

my @tf_data = (
    [1,  '1m'],
    [5,  '5m'],
    [15, '15m']
);

my @tf_buttons;

for my $tf_entry (@tf_data) {

    my ($tf, $label) = @$tf_entry;

    my $btn = $toolbar->Button(

        -text => $label,

        -font => ['Helvetica', 10, 'bold'],

        -background       => '#ffffff',
        -foreground       => '#374151',

        -activebackground => '#dbeafe',
        -activeforeground => '#1d4ed8',

        -relief => 'flat',

        -padx => 12,
        -pady => 4,

        -command => sub {},

    )->pack(
        -side => 'left',
        -padx => 2,
        -pady => 3
    );

    push @tf_buttons, [$tf, $btn];
}

# ------------------------------------------------------------------------------
# SEPARADOR
# ------------------------------------------------------------------------------

$toolbar->Label(

    -text => '|',

    -foreground => '#d1d5db',
    -background => '#f8fafc',

)->pack(
    -side => 'left',
    -padx => 4
);

# ------------------------------------------------------------------------------
# BOTON RESET
# ------------------------------------------------------------------------------

my $reset_btn = $toolbar->Button(

    -text => 'Reset',

    -font => ['Helvetica', 9],

    -background       => '#ffffff',
    -foreground       => '#6b7280',

    -activebackground => '#e5e7eb',
    -activeforeground => '#111827',

    -relief => 'flat',

    -padx => 8,

    -command => sub {},

)->pack(
    -side => 'left',
    -padx => 2
);

# ------------------------------------------------------------------------------
# LABEL AYUDA
# ------------------------------------------------------------------------------

$toolbar->Label(

    -text =>
'  Rueda=zoom  |  Drag=scroll  |  BtnDer=mover Y  |  DblClic=auto Y  |  1/5/F=temporalidad  |  R=reset',

    -foreground => '#6b7280',
    -background => '#f8fafc',

    -font => ['Helvetica', 8],

)->pack(
    -side => 'right',
    -padx => 8
);

# ------------------------------------------------------------------------------
# FRAME CHART
# ------------------------------------------------------------------------------

my $chart_frame = $main_frame->Frame(
    -background => '#ffffff'
)->pack(
    -fill   => 'both',
    -expand => 1
);

# ------------------------------------------------------------------------------
# PRICE CANVAS
# ------------------------------------------------------------------------------

my $price_canvas = $chart_frame->Canvas(

    -width  => $CANVAS_W,
    -height => $PRICE_H,

    -background => '#ffffff',

    -cursor => 'crosshair',

    -borderwidth        => 0,
    -highlightthickness => 0,

)->pack(
    -side   => 'top',
    -fill   => 'both',
    -expand => 1
);

# ------------------------------------------------------------------------------
# SEPARADOR ENTRE PANELES
# ------------------------------------------------------------------------------

$chart_frame->Frame(

    -background => '#e5e7eb',

    -height => 1,

)->pack(
    -side => 'top',
    -fill => 'x'
);

# ------------------------------------------------------------------------------
# ATR CANVAS
# ------------------------------------------------------------------------------

my $atr_canvas = $chart_frame->Canvas(

    -width  => $CANVAS_W,
    -height => $ATR_H,

    -background => '#ffffff',

    -cursor => 'crosshair',

    -borderwidth        => 0,
    -highlightthickness => 0,

)->pack(
    -side => 'top',
    -fill => 'x'
);

# ------------------------------------------------------------------------------
# 5. CHART ENGINE
# ------------------------------------------------------------------------------

my $engine = Market::ChartEngine->new(

    market       => $market,
    indicators   => $indicators,

    price_canvas => $price_canvas,
    atr_canvas   => $atr_canvas,

    canvas_w => $CANVAS_W,
    price_h  => $PRICE_H,
    atr_h    => $ATR_H,

    scale_w => $SCALE_W,

    visible_bars => $VISIBLE_BARS,
);

# ------------------------------------------------------------------------------
# BOTONES TIMEFRAME
# ------------------------------------------------------------------------------

for my $tf_entry (@tf_buttons) {

    my ($tf, $btn) = @$tf_entry;

    $btn->configure(
        -command => sub {

            $engine->set_timeframe($tf);

            $mw->title(
                "Market Chart | ${tf}m | NQ Futuros CME - Abril 2026"
            );
        }
    );
}

# ------------------------------------------------------------------------------
# BOTON RESET
# ------------------------------------------------------------------------------

$reset_btn->configure(
    -command => sub {

        $engine->reset_view();

        $engine->render();
    }
);

# ------------------------------------------------------------------------------
# REDIMENSIONAMIENTO
# ------------------------------------------------------------------------------

$price_canvas->bind(
    '<Configure>',
    sub {

        my $new_w =
            $price_canvas->width();

        my $new_h =
            $price_canvas->height();

        return
            if $new_w < 100
            || $new_h < 100;

        $engine->{canvas_w} = $new_w;
        $engine->{price_h}  = $new_h;

        $engine->{price_panel}{canvas_w} = $new_w;
        $engine->{price_panel}{canvas_h} = $new_h;

        $engine->{atr_panel}{canvas_w} = $new_w;

        $engine->request_render();
    }
);

$atr_canvas->bind(
    '<Configure>',
    sub {

        my $new_h =
            $atr_canvas->height();

        return
            if $new_h < 30;

        $engine->{atr_h} = $new_h;

        $engine->{atr_panel}{canvas_h} = $new_h;

        $engine->request_render();
    }
);

# ------------------------------------------------------------------------------
# 6. EVENTOS
# ------------------------------------------------------------------------------

$engine->bind_events();

print "Dibujando chart inicial...\n";

$engine->render();

$price_canvas->focus();

print "Sistema listo.\n";

MainLoop();

# ==============================================================================
# SUBRUTINAS
# ==============================================================================

# ------------------------------------------------------------------------------
# load_csv
# ------------------------------------------------------------------------------

sub load_csv {

    my ($file, $md) = @_;

    open(my $fh, '<', $file)
        or die "No se puede abrir '$file': $!\n";

    <$fh>;

    while (my $line = <$fh>) {

        chomp $line;

        next unless $line =~ /\S/;

        my (
            $time,
            $open,
            $high,
            $low,
            $close,
            $vol
        ) = split /,/, $line;

        $md->add_candle({

            time       => $time,

            time_epoch => iso_to_epoch($time),

            open  => $open  + 0,
            high  => $high  + 0,
            low   => $low   + 0,
            close => $close + 0,

            volume => $vol + 0,
        });
    }

    close $fh;
}

# ------------------------------------------------------------------------------
# iso_to_epoch
# ------------------------------------------------------------------------------

sub iso_to_epoch {

    my ($ts) = @_;

    return 0
        unless $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})([+-])(\d{2}):(\d{2})/;

    my (
        $yr,
        $mo,
        $dy,
        $hr,
        $mi,
        $se,
        $sign,
        $oh,
        $om
    ) = (
        $1,$2,$3,$4,$5,$6,$7,$8,$9
    );

    local $ENV{TZ} = 'UTC';

    my $epoch =
        mktime(
            $se,
            $mi,
            $hr,
            $dy,
            $mo - 1,
            $yr - 1900
        );

    my $offset =
        ($oh * 3600 + $om * 60)
        * ($sign eq '+' ? -1 : 1);

    return $epoch + $offset;
}

# ------------------------------------------------------------------------------
# _FakeMD
# ------------------------------------------------------------------------------

package _FakeMD;

sub last_candle {
    return $_[0]->{_c};
}
