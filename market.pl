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
use Market::Replay;

# --- Fase 2: motores analiticos y overlays SMC / Liquidez (Tabla 1) ---
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Overlays::SMC_Structures;
use Market::Overlays::Liquidity;

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

my $replay_frame = $mw->Frame(-background => '#eef0f5', -height => $TF_BAR_H)
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
my $market = Market::MarketData->new;

# Los tres archivos del proyecto en orden cronologico.
# 2026_03.csv es un archivo con nombre incorrecto que contiene datos de Abril;
# se usa como fallback de 2026_04.csv si este no existe (son identicos).
# Se salta cualquier vela con timestamp <= al ultimo ya cargado para evitar
# duplicados en caso de que los archivos se solapen.
my @csv_groups = (
    ['data/2026_04.csv', '2026_04.csv', '../data/2026_04.csv',
     'data/2026_03.csv', '2026_03.csv', '../data/2026_03.csv'],
    ['data/2026_05.csv', '2026_05.csv', '../data/2026_05.csv'],
    ['data/2026_06_29.csv', '2026_06_29.csv', '../data/2026_06_29.csv'],
);

my $count    = 0;
my $last_ts  = 0;

for my $paths (@csv_groups) {
    my $csv_path;
    for my $cand (@$paths) {
        if (-f $cand) { $csv_path = $cand; last; }
    }
    unless ($csv_path) {
        my $name = (grep { !m{/\.\.} } @$paths)[0] // $paths->[0];
        warn "CSV no encontrado (se continua sin el): $name\n";
        next;
    }

    print "Cargando $csv_path...\n";
    open my $fh, '<', $csv_path or die "Error abriendo CSV '$csv_path': $!\n";
    <$fh>;   # saltar cabecera
    while (<$fh>) {
        chomp;
        my ($time_str, $open, $high, $low, $close, $volume) = split /,/;
        next unless defined $close && $close ne '';
        my $tm;
        eval { $tm = Time::Moment->from_string($time_str) };
        next if $@;
        my $ts = $tm->epoch;
        next if $ts <= $last_ts;   # saltar duplicados / datos fuera de orden
        $last_ts = $ts;
        $market->add_candle({
            time   => $time_str,
            ts     => $ts,
            open   => $open  + 0,
            high   => $high  + 0,
            low    => $low   + 0,
            close  => $close + 0,
            volume => $volume + 0,
        });
        $count++;
    }
    close $fh;
}

printf "Cargadas %d velas de 1m\n", $count;
$market->build_timeframes;
printf "5m: %d | 15m: %d | 1h: %d | 2h: %d | 4h: %d | D: %d | W: %d\n",
    scalar @{ $market->get_data->{'5m'} },
    scalar @{ $market->get_data->{'15m'} },
    scalar @{ $market->get_data->{'1h'} },
    scalar @{ $market->get_data->{'2h'} },
    scalar @{ $market->get_data->{'4h'} },
    scalar @{ $market->get_data->{'D'} },
    scalar @{ $market->get_data->{'W'} };

# =============================================================================
# INDICADORES
# =============================================================================
my $ind_manager = Market::IndicatorManager->new;

# El ORDEN de registro importa: en cada vela, rebuild/update procesa los
# indicadores en este orden. Liquidity necesita el ATR ya calculado (tolerancia
# EQH/EQL) y SMC_Structures necesita los swings ya confirmados por Liquidity.
my $atr_ind = Market::Indicators::ATR->new(14);
my $liq_ind = Market::Indicators::Liquidity->new( atr => $atr_ind, k => 3 );
my $smc_ind = Market::Indicators::SMC_Structures->new(
    liquidity => $liq_ind, atr => $atr_ind, max_age => 50 );

$ind_manager->register('atr',       $atr_ind);
$ind_manager->register('liquidity', $liq_ind);
$ind_manager->register('smc',       $smc_ind);

print "Calculando indicadores (ATR, Liquidity, SMC)...\n";
$ind_manager->rebuild_all($market);
printf "ATR: %d  |  swings: %d  |  eventos liq: %d  |  FVGs: %d\n",
    scalar @{ $ind_manager->get('atr') },
    scalar @{ $liq_ind->get_swings },
    scalar @{ $liq_ind->get_events },
    scalar @{ $smc_ind->get_fvgs };

# =============================================================================
# OVERLAYS — gestor + overlays reales SMC y Liquidez (Tabla 1, Fase 2)
# Cada overlay solo DIBUJA estructuras ya calculadas por su indicador fuente
# (separacion estricta calculo/render). Nacen OCULTOS: el usuario decide que
# activar de forma independiente desde el menu de herramientas.
# =============================================================================
my $overlay_mgr = Market::OverlayManager->new;
my $smc_overlay = Market::Overlays::SMC_Structures->new(
    source => $smc_ind, max_age => 50 );
my $liq_overlay = Market::Overlays::Liquidity->new( source => $liq_ind );
$overlay_mgr->register('smc',       $smc_overlay, visible => 0);
$overlay_mgr->register('liquidity', $liq_overlay, visible => 0);

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
# REPLAY (Etapa 3, Fase 2)
# Los widgets referenciados en on_change se declaran aqui pero se crean
# mas abajo, en la barra $replay_frame -- mismo patron de closures que
# ya usa este archivo para sincronizar $mode_btn/$mode_btn_atr.
# =============================================================================
my ( $replay_status_lbl, $btn_replay_play, $btn_replay_pause,
     $btn_replay_step_fwd, $btn_replay_step_back, $btn_replay_fast,
     $btn_replay_exit );

my $replay;
$replay = Market::Replay->new(
    market     => $market,
    indicators => $ind_manager,
    schedule   => sub { $canvas_price->after(@_); },
    on_change  => sub {
        $engine->follow_replay_pointer;

        my $active  = $replay->is_active;
        my $playing = $replay->is_playing;

        if ($replay_status_lbl) {
            my $text = !$active
                ? 'EN VIVO (replay inactivo)'
                : sprintf(
                    'REPLAY %s | %s',
                    Time::Moment->from_epoch($replay->current_ts)
                        ->with_offset_same_instant(-300)->strftime('%Y-%m-%d %H:%M:%S'),
                    ($playing ? ($replay->is_fast ? 'FAST FORWARD' : 'PLAY') : 'PAUSADO'),
                );
            $replay_status_lbl->configure(-text => $text);
        }

        for my $pair (
            [ $btn_replay_play,       $active ],
            [ $btn_replay_pause,      $active && $playing ],
            [ $btn_replay_step_fwd,   $active && !$playing ],
            [ $btn_replay_step_back,  $active && !$playing ],
            [ $btn_replay_fast,       $active ],
            [ $btn_replay_exit,       $active ],
        ) {
            my ($btn, $enabled) = @$pair;
            next unless $btn;
            $btn->configure(-state => $enabled ? 'normal' : 'disabled');
        }
    },
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
# BARRA DE REPLAY (Etapa 3, Fase 2)
# =============================================================================
$replay_frame->Label(%bs, -text => 'Replay desde:')
    ->pack(-side => 'left', -padx => 6);

# Prefill con el timestamp de la vela intermedia del CSV cargado (1m),
# en el mismo formato ISO que ya usa el propio CSV -- editable por el
# usuario, parseado con el mismo Time::Moment->from_string que usa la
# carga del archivo.
my $default_replay_str = $market->raw_get_candle( int($market->raw_size / 2) )->{time};
my $replay_date_var = $default_replay_str;
my $replay_entry = $replay_frame->Entry(
    -textvariable => \$replay_date_var,
    -width        => 26,
    -font         => 'TkFixedFont 9',
)->pack(-side => 'left', -padx => 2, -pady => 2);

my $btn_replay_start = $replay_frame->Button(%bs,
    -text    => 'Inicio Replay',
    -command => sub {
        my $tm;
        eval { $tm = Time::Moment->from_string($replay_date_var) };
        if ($@ || !$tm) {
            $replay_status_lbl->configure(
                -text => "Fecha invalida: '$replay_date_var' (formato esperado: 2026-04-15T12:00:00-05:00)"
            );
            return;
        }
        $replay->start($tm->epoch);
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$replay_frame->Frame(-background => '#c9cdd7', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

$btn_replay_step_back = $replay_frame->Button(%bs,
    -text    => '|< Step',
    -state   => 'disabled',
    -command => sub { $replay->step_backward(1); },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_play = $replay_frame->Button(%bs,
    -text    => 'Play',
    -state   => 'disabled',
    -command => sub { $replay->play; },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_pause = $replay_frame->Button(%bs,
    -text    => 'Pause',
    -state   => 'disabled',
    -command => sub { $replay->pause; },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_step_fwd = $replay_frame->Button(%bs,
    -text    => 'Step >|',
    -state   => 'disabled',
    -command => sub { $replay->step_forward(1); },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$btn_replay_fast = $replay_frame->Button(%bs,
    -text    => 'Fast Forward >>',
    -state   => 'disabled',
    -command => sub { $replay->fast_forward; },
)->pack(-side => 'left', -padx => 1, -pady => 2);

$replay_frame->Frame(-background => '#c9cdd7', -width => 1, -height => 16)
    ->pack(-side => 'left', -pady => 5, -padx => 6);

$btn_replay_exit = $replay_frame->Button(%bs,
    -text       => 'Exit Replay',
    -foreground => '#ef5350',
    -state      => 'disabled',
    -command    => sub { $replay->exit_replay; },
)->pack(-side => 'left', -padx => 4, -pady => 2);

$replay_status_lbl = $replay_frame->Label(%bs,
    -text       => 'EN VIVO (replay inactivo)',
    -foreground => '#363a45',
    -font       => 'TkDefaultFont 9 bold',
)->pack(-side => 'left', -padx => 10);

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
# MENU DE HERRAMIENTAS / OVERLAYS (Fase 2)
# Cada herramienta tiene su PROPIO estado de activacion: marcar una opcion
# NUNCA activa las demas. La visibilidad de un overlay completo = (alguna de
# sus sub-opciones activa). El menu SOLO administra estados y dispara render;
# no calcula ni dibuja directamente.
# =============================================================================
my $BAR_BG   = '#eef1f5';
my $PANEL_BG = '#f7f8fa';

my %BBS = (
    -background       => $BAR_BG,
    -activebackground => '#dde0e8',
    -foreground       => '#363a45',
    -relief           => 'flat',
    -bd               => 0,
    -font             => 'TkDefaultFont 9',
    -padx             => 5,
    -pady             => 2,
);

# --- Fila "Herramientas:" con el toggle del panel ---
my $tools_bar = $mw->Frame(-background => $BAR_BG);
$tools_bar->pack(-side => 'top', -fill => 'x', -before => $canvas_price);
$tools_bar->Label(-text => 'Herramientas:', -background => $BAR_BG,
    -foreground => '#363a45', -font => 'TkDefaultFont 9 bold')
    ->pack(-side => 'left', -padx => 8, -pady => 3);

# --- Panel colapsable con las columnas de checkbuttons ---
# Nace COLAPSADO: la app arranca limpia, sin overlays activos ni panel abierto.
my $tools_panel = $mw->Frame(-background => $PANEL_BG);

my $panel_shown = 0;
my $panel_btn;
$panel_btn = $tools_bar->Button(%BBS,
    -text => 'Overlays [>]', -foreground => '#2962ff',
    -font => 'TkDefaultFont 9 bold',
    -command => sub {
        $panel_shown = !$panel_shown;
        if ($panel_shown) {
            $tools_panel->pack(-side=>'top', -fill=>'x', -before=>$canvas_price);
            $panel_btn->configure(-text => 'Overlays [v]');
        } else {
            $tools_panel->packForget;
            $panel_btn->configure(-text => 'Overlays [>]');
        }
    },
)->pack(-side => 'left', -padx => 4, -pady => 2);
$tools_bar->Label(-text => 'Clic en cada herramienta para activar/desactivar de forma independiente',
    -background => $BAR_BG, -foreground => '#787b86', -font => 'TkDefaultFont 8')
    ->pack(-side => 'right', -padx => 10);

# --- Helpers de construccion del menu ---
my $make_col = sub {
    my ($title, $color) = @_;
    my $col = $tools_panel->Frame(-background => $PANEL_BG);
    $col->pack(-side => 'left', -anchor => 'n', -padx => 14, -pady => 6);
    $col->Label(-text => $title, -background => $PANEL_BG, -foreground => $color,
        -font => 'TkDefaultFont 9 bold')->pack(-side => 'top', -anchor => 'w');
    return $col;
};
my $make_chk = sub {
    my ($parent, $text, $varref, $cmd, $disabled) = @_;
    my $cb = $parent->Checkbutton(
        -text => $text, -variable => $varref, -onvalue => 1, -offvalue => 0,
        -background => $PANEL_BG, -activebackground => $PANEL_BG,
        -font => 'TkDefaultFont 8', -anchor => 'w',
        ( $cmd ? ( -command => $cmd ) : () ),
    );
    $cb->configure(-state => 'disabled') if $disabled;
    $cb->pack(-side => 'top', -anchor => 'w', -fill => 'x');
    return $cb;
};

# =============================================================================
# Columna SMC STRUCTURES (Estructura HH/HL/LH/LL / BOS / CHoCH / FVG / OB)
# =============================================================================
my %SMC = ( show_struct => 0, show_fvg => 0, show_bos => 0, show_choch => 0, show_obs => 0 );
my $smc_master = 0;
my $refresh_smc = sub {
    $smc_overlay->set_flag($_, $SMC{$_}) for keys %SMC;
    my $any = 0; $any ||= $SMC{$_} for keys %SMC;
    $overlay_mgr->set_visible('smc', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_smc_master = sub {
    my $all = 1; $all &&= $SMC{$_} for keys %SMC;
    $smc_master = $all ? 1 : 0;
};
my $leaf_smc = sub { $refresh_smc->(); $sync_smc_master->(); };

my $col_smc = $make_col->('SMC Structures', '#2962ff');
$make_chk->($col_smc, 'Activar SMC', \$smc_master, sub {
    $SMC{$_} = $smc_master for keys %SMC;   # master = encender/apagar TODO SMC
    $refresh_smc->();
});
$make_chk->($col_smc, 'Estructura (HH/HL/LH/LL)', \$SMC{show_struct}, $leaf_smc);
$make_chk->($col_smc, 'BOS',       \$SMC{show_bos},   $leaf_smc);
$make_chk->($col_smc, 'CHoCH',     \$SMC{show_choch}, $leaf_smc);
$make_chk->($col_smc, 'FVG',       \$SMC{show_fvg},   $leaf_smc);
$make_chk->($col_smc, 'Order Blocks', \$SMC{show_obs}, $leaf_smc);

# =============================================================================
# Columna LIQUIDITY (Swing / BSL / SSL / EQH / EQL / Sweeps / Grabs / Runs)
# =============================================================================
my %LIQ = (
    show_swing => 0, show_bsl => 0, show_ssl => 0, show_eqh => 0,
    show_eql => 0, show_sweeps => 0, show_grabs => 0, show_runs => 0,
);
my $liq_master = 0;
my $refresh_liq = sub {
    $liq_overlay->set_flag($_, $LIQ{$_}) for keys %LIQ;
    my $any = 0; $any ||= $LIQ{$_} for keys %LIQ;
    $overlay_mgr->set_visible('liquidity', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_liq_master = sub {
    my $all = 1; $all &&= $LIQ{$_} for keys %LIQ;
    $liq_master = $all ? 1 : 0;
};
my $leaf_liq = sub { $refresh_liq->(); $sync_liq_master->(); };

my $col_liq = $make_col->('Liquidity', '#ef5350');
$make_chk->($col_liq, 'Activar Liquidity', \$liq_master, sub {
    $LIQ{$_} = $liq_master for keys %LIQ;
    $refresh_liq->();
});
$make_chk->($col_liq, 'Swing Points',  \$LIQ{show_swing},  $leaf_liq);
$make_chk->($col_liq, 'BSL - Buy Side',  \$LIQ{show_bsl},  $leaf_liq);
$make_chk->($col_liq, 'SSL - Sell Side', \$LIQ{show_ssl},  $leaf_liq);
$make_chk->($col_liq, 'EQH',     \$LIQ{show_eqh},    $leaf_liq);
$make_chk->($col_liq, 'EQL',     \$LIQ{show_eql},    $leaf_liq);
$make_chk->($col_liq, 'Sweeps',  \$LIQ{show_sweeps}, $leaf_liq);
$make_chk->($col_liq, 'Grabs',   \$LIQ{show_grabs},  $leaf_liq);
$make_chk->($col_liq, 'Runs',    \$LIQ{show_runs},   $leaf_liq);

# =============================================================================
# PRIMER RENDER
# =============================================================================
$engine->reset_view;
$mw->after(80, sub { $engine->render });
MainLoop;