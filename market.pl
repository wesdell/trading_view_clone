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
use Market::Indicators::ZigZag;
use Market::Overlays::ZigZag;
use Market::Overlays::Fibonacci;
use Market::Indicators::DailyLevels;
use Market::Overlays::DailyLevels;
use Market::Indicators::Strategy_Builder;   # FASE-2.3: DIY Custom Strategy Builder
use Market::Overlays::Strategy_Builder;
use Market::Indicators::VolumeProfile;       # FASE-2.4: Perfil de Volumen avanzado
use Market::Overlays::VolumeProfile;
use Market::Indicators::AnchoredVWAP;         # FASE-2.5: Anchored VWAP multipivote
use Market::Overlays::AnchoredVWAP;

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

# Los archivos del proyecto en orden cronologico.
# 2026_03.csv es un archivo con nombre incorrecto que contiene datos de Abril;
# se usa como fallback de 2026_04.csv si este no existe (son identicos).
# Se salta cualquier vela con timestamp <= al ultimo ya cargado para evitar
# duplicados en caso de que los archivos se solapen.
my @csv_groups = (
    ['data/2026_04.csv', '2026_04.csv', '../data/2026_04.csv',
     'data/2026_03.csv', '2026_03.csv', '../data/2026_03.csv'],
    ['data/2026_05.csv', '2026_05.csv', '../data/2026_05.csv'],
    ['data/2026_06.csv', '2026_06.csv', '../data/2026_06.csv'],
    # Cuarto grupo (entrega 2): continua la serie desde donde termina
    # 2026_06_29.csv. Si hay velas solapadas entre ambos archivos (este
    # arranca el 2026-07-01), el guard $last_ts de mas abajo las descarta
    # automaticamente -- mismo mecanismo que ya filtra el duplicado
    # 2026_03.csv/2026_04.csv, no requiere logica nueva.
    ['data/2026_07_13.csv', '2026_07_13.csv', '../data/2026_07_13.csv'],
);

# -----------------------------------------------------------------------------
# FIX (entrega 2): dedup por TIMESTAMP EXACTO via hash, no por "monotono
# creciente" via un simple $last_ts. Con el guard anterior (next if $ts <=
# $last_ts) el archivo mas VIEJO en @csv_groups ganaba cualquier solape --
# como 2026_06_29.csv se carga ANTES que 2026_07_13.csv, si el primero ya
# traia datos parciales/preliminares de julio, esos quedaban visibles y las
# velas correctas del archivo nuevo para esas mismas fechas se descartaban
# en silencio. Efecto observado: todas las temporalidades intradia
# (5m/15m/30m/1h/2h/4h/D) mostraban julio mal, mientras que W se veia bien
# porque una vela semanal diluye el error entre miles de velas de 1m.
#
# Ahora se indexa cada vela por su epoch en %by_ts recorriendo los grupos en
# orden: si dos archivos traen la MISMA vela (mismo ts), el que se procesa
# DESPUES (mas nuevo/mas autoritativo, por convencion de orden en
# @csv_groups) sobre-escribe al anterior. Al final se ordena por ts y se
# alimenta a MarketData -- el orden final de insercion es siempre
# cronologico, igual que antes.
# -----------------------------------------------------------------------------
my %by_ts;

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

        # Sobre-escribe silenciosamente si ya existia (archivo mas nuevo gana).
        $by_ts{$ts} = {
            time   => $time_str,
            ts     => $ts,
            open   => $open  + 0,
            high   => $high  + 0,
            low    => $low   + 0,
            close  => $close + 0,
            volume => $volume + 0,
        };
    }
    close $fh;
}

my $count = 0;
for my $ts (sort { $a <=> $b } keys %by_ts) {
    $market->add_candle($by_ts{$ts});
    $count++;
}

printf "Cargadas %d velas de 1m\n", $count;
$market->build_timeframes;
printf "5m: %d | 15m: %d | 30m: %d | 1h: %d | 2h: %d | 4h: %d | D: %d | W: %d\n",
    scalar @{ $market->get_data->{'5m'} },
    scalar @{ $market->get_data->{'15m'} },
    scalar @{ $market->get_data->{'30m'} },
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
# EQH/EQL). ZigZag debe procesarse ANTES que SMC_Structures: las etiquetas
# HH/HL/LH/LL de SMC_Structures espejan los pivotes del ZigZag INTERNO
# (verde/rojo) de este mismo tick (ver Indicators::SMC_Structures::_sync_from_zigzag).
my $atr_ind = Market::Indicators::ATR->new(14);
my $liq_ind = Market::Indicators::Liquidity->new( atr => $atr_ind, k => 3 );

# ZigZag interno: replica ZZMTF (Resolution=30min, Period=2)
# ZigZag externo: replica ZigZag Volume Profile (Length=150 velas de la TF activa)
my $zz_ind = Market::Indicators::ZigZag->new(
    int_period  => 2,       # ZZMTF Period=2
    int_tf_mins => 30,      # ZZMTF Resolution=30min => ventana=2*30=60 velas 1m
    ext_length  => 150,     # ZigZag Volume Profile Length=150
);
my $smc_ind = Market::Indicators::SMC_Structures->new(
    zigzag => $zz_ind, atr => $atr_ind, max_age => 50,
    liquidity => $liq_ind );   # FASE-2.2: SMC consume (no recalcula) los eventos de Liquidity

# FASE-2.3: Strategy Builder (5 componentes + combinador). Regla por defecto
# operativa (combinable/seleccionable desde los checkboxes); componentes se
# calculan siempre, independientes de la seleccion de reglas.
my $sb_ind = Market::Indicators::Strategy_Builder->new(
    rules => {
        entry => { conds => ['st_flip_up',   'rf_up'],   mode => 'AND', side => 'long'  },
        exit  => { conds => ['st_flip_down', 'ht_down'], mode => 'OR',  side => 'long'  },
    },
);

# FASE-2.4: Perfil de Volumen (modo sesion por defecto; recibe SMC para el modo
# BOS/CHoCH). Se registra DESPUES de SMC para consumir sus eventos confirmados.
my $vp_ind = Market::Indicators::VolumeProfile->new(
    mode => 'session', nbins => 50, va_pct => 0.70, smc => $smc_ind );

# FASE-2.5: Anchored VWAP multipivote (consume BOS/CHoCH de SMC y POC de VP;
# se registra DESPUES de ambos para leer sus salidas confirmadas de la vela i).
my $vwap_ind = Market::Indicators::AnchoredVWAP->new(
    smc => $smc_ind, vp => $vp_ind, anchor_scope => 'external' );

# FASE-2.6 -- FLUJO OBLIGATORIO POR VELA. El orden de registro ES el orden de
# actualizacion en rebuild_all/update_last (bars-outer x indicadores-inner). Las
# dependencias son UNIDIRECCIONALES: cada consumidor se registra DESPUES de sus
# productores. (Reordenar indicadores independientes NO cambia resultados.)
$ind_manager->register('atr',       $atr_ind);   # (2) ATR base / temporalidades
$ind_manager->register('zigzag',    $zz_ind);    # (3) estructura HH/HL (alimenta SMC)
$ind_manager->register('liquidity', $liq_ind);   # (4,5,8) Liquidity + eventos + volumen multi-TF
$ind_manager->register('smc',       $smc_ind);   # (6,7) BOS/CHoCH + FVG (lee zigzag + liquidity)
$ind_manager->register('vp',        $vp_ind);    # (9) Volume Profile (lee eventos SMC)
$ind_manager->register('vwap',      $vwap_ind);  # (10) Anchored VWAP (lee SMC + VP)
$ind_manager->register('strategy',  $sb_ind);    # (11) Strategy Builder (independiente)

# Soporte/Resistencia por coincidencia mas cercana (revision ingeniero,
# entrega 2): independiente, lee D/4h directo de MarketData, no depende de
# ningun otro indicador de esta lista.
my $daily_lv_ind = Market::Indicators::DailyLevels->new;
$ind_manager->register('daily_lv',  $daily_lv_ind);

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

my $zz_overlay = Market::Overlays::ZigZag->new( source => $zz_ind );
$overlay_mgr->register('zigzag', $zz_overlay, visible => 0);

my $fib_overlay = Market::Overlays::Fibonacci->new( source => $zz_ind );
$overlay_mgr->register('fibonacci', $fib_overlay, visible => 0);

my $daily_lv_overlay = Market::Overlays::DailyLevels->new( source => $daily_lv_ind );
$overlay_mgr->register('daily_lv', $daily_lv_overlay, visible => 0);

my $sb_overlay = Market::Overlays::Strategy_Builder->new( source => $sb_ind );  # FASE-2.3
$overlay_mgr->register('strategy', $sb_overlay, visible => 0);

my $vp_overlay = Market::Overlays::VolumeProfile->new( source => $vp_ind );     # FASE-2.4
$overlay_mgr->register('volumeprofile', $vp_overlay, visible => 0);

my $vwap_overlay = Market::Overlays::AnchoredVWAP->new( source => $vwap_ind );  # FASE-2.5
$overlay_mgr->register('avwap', $vwap_overlay, visible => 0);

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
     $btn_replay_exit, $btn_replay_select );

# Estado de la seleccion de vela de inicio (spec 19: REPLAY_SELECTING_START).
# $refresh_replay_buttons se asigna mas abajo, tras crear los botones, y es la
# UNICA fuente de verdad para habilitar/deshabilitar la barra de replay.
my $replay_selecting = 0;
my $refresh_replay_buttons;

my $replay;
$replay = Market::Replay->new(
    market     => $market,
    indicators => $ind_manager,
    schedule   => sub { $canvas_price->after(@_); },
    cancel     => sub { my ($id) = @_; $canvas_price->afterCancel($id) if defined $id; },
    on_change  => sub {
        $engine->follow_replay_pointer;

        my $active  = $replay->is_active;
        my $playing = $replay->is_playing;

        # Al salir del replay, quitar el marcador de inicio.
        $engine->clear_replay_start_marker unless $active;

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

        $refresh_replay_buttons->() if $refresh_replay_buttons;
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
$replay_frame->Label(%bs, -text => 'Replay:')
    ->pack(-side => 'left', -padx => 6);

# Seleccion de la vela de inicio POR CLIC (spec 18-20): el usuario pulsa este
# boton, el grafico entra en modo seleccion (se bloquean los botones de replay)
# y el proximo clic sobre una vela define el punto de arranque. Vuelve a pulsar
# (o Escape) para cancelar. Sin TextField ni fechas.
$btn_replay_select = $replay_frame->Button(%bs,
    -text    => 'Seleccionar Inicio',
    -command => sub {
        # Segundo clic en el boton = cancelar la seleccion en curso.
        if ($replay_selecting) {
            $engine->cancel_candle_pick;
            $replay_selecting = 0;
            $replay_status_lbl->configure(
                -text => $replay->is_active
                    ? 'REPLAY (seleccion cancelada)'
                    : 'EN VIVO (replay inactivo)'
            );
            $refresh_replay_buttons->();
            return;
        }

        # Entrar en modo seleccion: pausar cualquier reproduccion en curso,
        # bloquear botones y esperar el clic.
        $replay->pause if $replay->is_playing;
        $replay_selecting = 1;
        $replay_status_lbl->configure(
            -text => 'Seleccione una vela para iniciar el replay'
        );
        $refresh_replay_buttons->();

        $engine->begin_candle_pick(sub {
            my ($idx, $c) = @_;
            $replay_selecting = 0;
            if ($c) {
                # Marca visual en la vela elegida (fecha/hora) para confirmar
                # desde donde arranca el replay.
                my $when = Time::Moment->from_epoch($c->{ts})
                    ->with_offset_same_instant(-300)
                    ->strftime('%Y-%m-%d %H:%M');
                $engine->set_replay_start_marker($idx, $when);
                # start() dispara on_change, que refresca la barra de replay.
                $replay->start($c->{ts});
            }
            else {
                # Cancelado con Escape sin elegir vela.
                $replay_status_lbl->configure(
                    -text => $replay->is_active
                        ? 'REPLAY (seleccion cancelada)'
                        : 'EN VIVO (replay inactivo)'
                );
                $refresh_replay_buttons->();
            }
        });
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

# -----------------------------------------------------------------------------
# refresh_replay_buttons: sincroniza la barra de replay con el estado (spec 19).
#   - Durante la seleccion de vela ($replay_selecting) TODOS los botones de
#     accion quedan bloqueados; el boton de seleccion pasa a "Cancelar".
#   - Fuera de seleccion, se habilitan segun replay activo / en reproduccion.
# Se llama desde on_change (arranque/paso/play/pausa/salida) y desde la propia
# logica de seleccion.
# -----------------------------------------------------------------------------
$refresh_replay_buttons = sub {
    my $active  = $replay->is_active;
    my $playing = $replay->is_playing;
    my $sel     = $replay_selecting;

    for my $pair (
        [ $btn_replay_play,      !$sel && $active ],
        [ $btn_replay_pause,     !$sel && $active && $playing ],
        [ $btn_replay_step_fwd,  !$sel && $active && !$playing ],
        [ $btn_replay_step_back, !$sel && $active && !$playing ],
        [ $btn_replay_fast,      !$sel && $active ],
        [ $btn_replay_exit,      !$sel && $active ],
    ) {
        my ($btn, $enabled) = @$pair;
        next unless $btn;
        $btn->configure(-state => $enabled ? 'normal' : 'disabled');
    }

    if ($btn_replay_select) {
        $btn_replay_select->configure(
            -text  => $sel ? 'Cancelar seleccion' : 'Seleccionar Inicio',
            -state => 'normal',
        );
    }
};

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
# Columna STRATEGY BUILDER (SuperTrend / HalfTrend / Range Filter /
# Supply / Demand / Senales). FASE-2.3. Mismos controles/patron existentes.
# =============================================================================
my %SB = (
    show_supertrend => 0, show_halftrend => 0, show_rangefilter => 0,
    show_supply => 0, show_demand => 0, show_signals => 0,
);
my $sb_master = 0;
my $refresh_sb = sub {
    $sb_overlay->set_flag($_, $SB{$_}) for keys %SB;
    my $any = 0; $any ||= $SB{$_} for keys %SB;
    $overlay_mgr->set_visible('strategy', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_sb_master = sub { my $all = 1; $all &&= $SB{$_} for keys %SB; $sb_master = $all ? 1 : 0; };
my $leaf_sb = sub { $refresh_sb->(); $sync_sb_master->(); };

my $col_sb = $make_col->('Strategy Builder', '#42a5f5');
$make_chk->($col_sb, 'Activar Strategy', \$sb_master, sub {
    $SB{$_} = $sb_master for keys %SB; $refresh_sb->();
});
$make_chk->($col_sb, 'SuperTrend',   \$SB{show_supertrend},  $leaf_sb);
$make_chk->($col_sb, 'HalfTrend',    \$SB{show_halftrend},   $leaf_sb);
$make_chk->($col_sb, 'Range Filter', \$SB{show_rangefilter}, $leaf_sb);
$make_chk->($col_sb, 'Supply Zones', \$SB{show_supply},      $leaf_sb);
$make_chk->($col_sb, 'Demand Zones', \$SB{show_demand},      $leaf_sb);
$make_chk->($col_sb, 'Senales',      \$SB{show_signals},     $leaf_sb);

# =============================================================================
# Columna VOLUME PROFILE (POC / Value Area / Histograma / Ancla). FASE-2.4.
# Modo sesion por defecto; POC/VAH/VAL a precio fijo (no cambian con zoom).
# =============================================================================
my %VP = ( show_poc => 0, show_va => 0, show_hist => 0, show_anchor => 0 );
my $vp_master = 0;
my $refresh_vp = sub {
    $vp_overlay->set_flag($_, $VP{$_}) for keys %VP;
    my $any = 0; $any ||= $VP{$_} for keys %VP;
    $overlay_mgr->set_visible('volumeprofile', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_vp_master = sub { my $all = 1; $all &&= $VP{$_} for keys %VP; $vp_master = $all ? 1 : 0; };
my $leaf_vp = sub { $refresh_vp->(); $sync_vp_master->(); };

my $col_vp = $make_col->('Volume Profile', '#ff9800');
$make_chk->($col_vp, 'Activar Volume Profile', \$vp_master, sub {
    $VP{$_} = $vp_master for keys %VP; $refresh_vp->();
});
$make_chk->($col_vp, 'POC',        \$VP{show_poc},    $leaf_vp);
$make_chk->($col_vp, 'Value Area (VAH/VAL)', \$VP{show_va}, $leaf_vp);
$make_chk->($col_vp, 'Histograma', \$VP{show_hist},   $leaf_vp);
$make_chk->($col_vp, 'Ancla',      \$VP{show_anchor}, $leaf_vp);

# =============================================================================
# Columna ANCHORED VWAP (5 anclas: Sesion / Apertura / BOS / CHoCH / POC).
# FASE-2.5. Multipivote: varias anclas activas a la vez.
# =============================================================================
my %AV = ( show_session => 0, show_open => 0, show_bos => 0, show_choch => 0, show_poc => 0 );
my $av_master = 0;
my $refresh_av = sub {
    $vwap_overlay->set_flag($_, $AV{$_}) for keys %AV;
    my $any = 0; $any ||= $AV{$_} for keys %AV;
    $overlay_mgr->set_visible('avwap', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_av_master = sub { my $all = 1; $all &&= $AV{$_} for keys %AV; $av_master = $all ? 1 : 0; };
my $leaf_av = sub { $refresh_av->(); $sync_av_master->(); };

my $col_av = $make_col->('Anchored VWAP', '#26a69a');
$make_chk->($col_av, 'Activar VWAP', \$av_master, sub {
    $AV{$_} = $av_master for keys %AV; $refresh_av->();
});
$make_chk->($col_av, 'Inicio sesion',   \$AV{show_session}, $leaf_av);
$make_chk->($col_av, 'Apertura mercado', \$AV{show_open},   $leaf_av);
$make_chk->($col_av, 'BOS',   \$AV{show_bos},   $leaf_av);
$make_chk->($col_av, 'CHoCH', \$AV{show_choch}, $leaf_av);
$make_chk->($col_av, 'POC',   \$AV{show_poc},   $leaf_av);

# =============================================================================
# Columna ZIGZAG (Interno verde/rojo + Externo azul) — ultima columna: la
# resolucion del interno se elige con una fila de botones horizontales
# (mismo patron visual que el selector de temporalidad del grafico), no con
# un Optionmenu (no abria el menu de forma confiable en Tk).
# =============================================================================
my %ZZ = ( show_internal => 0, show_external => 0 );
my $zz_master = 0;
my $refresh_zz = sub {
    $zz_overlay->set_flag($_, $ZZ{$_}) for keys %ZZ;
    my $any = 0; $any ||= $ZZ{$_} for keys %ZZ;
    $overlay_mgr->set_visible('zigzag', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_zz_master = sub {
    my $all = 1; $all &&= $ZZ{$_} for keys %ZZ;
    $zz_master = $all ? 1 : 0;
};
my $leaf_zz = sub { $refresh_zz->(); $sync_zz_master->(); };

my $col_zz = $make_col->('ZigZag', '#1e88e5');
$make_chk->($col_zz, 'Activar ZigZag', \$zz_master, sub {
    $ZZ{$_} = $zz_master for keys %ZZ;
    $refresh_zz->();
});
$make_chk->($col_zz, 'Interno',   \$ZZ{show_internal}, $leaf_zz);
$make_chk->($col_zz, 'Externo (150)',   \$ZZ{show_external}, $leaf_zz);

# --- Resolucion del ZigZag interno (equivalente al input "ZigZag Resolution"
# del ZZMTF de TradingView). Cambiarla solo recalcula el zigzag interno
# (Market::IndicatorManager::rebuild_one) -- el resto de indicadores
# (externo, liquidity, SMC, etc.) no se tocan.
$col_zz->Label(-text => 'Interno - Resolucion:', -background => $PANEL_BG,
    -foreground => '#787b86', -font => 'TkDefaultFont 8')
    ->pack(-side => 'top', -anchor => 'w', -pady => [6, 0]);

my @ZZ_RES_OPTIONS = qw(1m 2m 3m 5m 10m 15m 30m 45m 1h 2h 3h 4h 1D 1S);
my $zz_int_res = '30m';   # debe calzar con int_tf_mins=>30 del constructor
my %zz_res_btns;

my $zz_res_row1 = $col_zz->Frame(-background => $PANEL_BG);
$zz_res_row1->pack(-side => 'top', -anchor => 'w', -fill => 'x');
my $zz_res_row2 = $col_zz->Frame(-background => $PANEL_BG);
$zz_res_row2->pack(-side => 'top', -anchor => 'w', -fill => 'x');

my $apply_zz_resolution = sub {
    my $mins = $Market::Indicators::ZigZag::RESOLUTION_MINUTES{$zz_int_res}
        or return;
    $zz_ind->set_int_resolution($mins);
    $ind_manager->rebuild_one('zigzag', $market);
    $engine->request_render;
};

my $zz_res_i = 0;
for my $res (@ZZ_RES_OPTIONS) {
    my $row = $zz_res_i < 7 ? $zz_res_row1 : $zz_res_row2;
    my $btn = $row->Button(
        -text             => $res,
        -background       => $PANEL_BG,
        -activebackground => $PANEL_BG,
        -foreground       => ($res eq $zz_int_res ? '#2962ff' : '#787b86'),
        -relief           => 'flat',
        -bd               => 0,
        -font             => 'TkDefaultFont 8 bold',
        -padx             => 3,
        -pady             => 1,
        -command          => sub {
            return if $zz_int_res eq $res;
            $zz_int_res = $res;
            for my $k (keys %zz_res_btns) {
                $zz_res_btns{$k}->configure(
                    -foreground => ($k eq $res ? '#2962ff' : '#787b86'));
            }
            $apply_zz_resolution->();
        },
    )->pack(-side => 'left', -padx => 1, -pady => 1);
    $zz_res_btns{$res} = $btn;
    $zz_res_i++;
}

# Fibonacci es un OVERLAY INDEPENDIENTE (no un flag del zigzag) porque solo
# necesita LEER los segmentos ya confirmados del ZigZag externo -- ver
# Overlays::Fibonacci. Se ubica en esta columna porque conceptualmente
# depende del externo, pero su visibilidad se maneja aparte en OverlayManager.
my $fib_visible = 0;
$make_chk->($col_zz, 'Fibonacci (tramo estable)', \$fib_visible, sub {
    $overlay_mgr->set_visible('fibonacci', $fib_visible);
    $engine->request_render;
});

# =============================================================================
# Columna SOPORTE/RESISTENCIA (Daily HL / 4H HL, coincidencia mas cercana,
# revision del ingeniero, entrega 2). Independiente de la TF activa --
# "Show Daily HL" pedido explicitamente visible desde 1m.
# =============================================================================
my %SR = ( show_daily => 0, show_4h => 0 );
my $sr_master = 0;
my $refresh_sr = sub {
    $daily_lv_overlay->set_flag($_, $SR{$_}) for keys %SR;
    my $any = 0; $any ||= $SR{$_} for keys %SR;
    $overlay_mgr->set_visible('daily_lv', $any ? 1 : 0);
    $engine->request_render;
};
my $sync_sr_master = sub {
    my $all = 1; $all &&= $SR{$_} for keys %SR;
    $sr_master = $all ? 1 : 0;
};
my $leaf_sr = sub { $refresh_sr->(); $sync_sr_master->(); };

my $col_sr = $make_col->('Soporte/Resistencia', '#6d4c41');
$make_chk->($col_sr, 'Activar S/R', \$sr_master, sub {
    $SR{$_} = $sr_master for keys %SR;
    $refresh_sr->();
});
$make_chk->($col_sr, 'Show Daily HL', \$SR{show_daily}, $leaf_sr);
$make_chk->($col_sr, 'Show 4H HL',    \$SR{show_4h},    $leaf_sr);

# =============================================================================
# PRIMER RENDER
# =============================================================================
$engine->reset_view;
$mw->after(80, sub { $engine->render });
MainLoop;