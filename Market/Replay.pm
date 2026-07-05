package Market::Replay;

# =============================================================================
# Market::Replay
# Responsabilidad: orquestar el modo Replay (Inicio/Play/Pause/Step
# Forward/Step Backward/Fast Forward/Exit) sobre un Market::MarketData.
#
# No conoce Tk directamente: recibe un callback "schedule" generico
# (sub($delay_ms, $cb) -> programa $cb tras $delay_ms) para los ticks
# automaticos de Play/Fast Forward, y un callback "on_change" para
# notificar a la UI cada vez que el estado cambia (arranque, paso,
# play/pausa, salida), sin acoplarse a ningun widget concreto.
#
# Politica de recalculo (decision de arquitectura, Etapa 0):
#   - Avance hacia adelante (step_forward / Play / Fast Forward) sin
#     cambio de temporalidad -> INCREMENTAL, vela por vela, via
#     IndicatorManager::update_last. Se procesa una vela a la vez aunque
#     el paso sea multiple (Fast Forward) para que cada indicador vea
#     exactamente la misma secuencia que veria en streaming real.
#   - Retroceso (step_backward) -> SIEMPRE rebuild completo
#     (IndicatorManager::reset_all + rebuild_all). El ATR tolera
#     reconstruirse por ser determinista hacia adelante, pero la futura
#     maquina de estados de Liquidez (Detected->Swept->...->Resolved)
#     no es reversible limpiamente, asi que ningun retroceso hace
#     excepcion, ni siquiera de una sola vela.
#   - Cambio de temporalidad durante el replay: NO se maneja aqui.
#     ChartEngine::set_timeframe ya hace reset_all+rebuild_all
#     incondicionalmente en cada cambio de TF; como MarketData es
#     consciente de la frontera de replay de forma transparente
#     (ver _effective_last_index), ese rebuild automaticamente respeta
#     el puntero vigente sin cambios adicionales en ningun lado.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        market     => $args{market},
        indicators => $args{indicators},
        schedule   => $args{schedule},    # sub($delay_ms, $cb) -> devuelve after_id
        cancel     => $args{cancel},      # sub($after_id)       -> afterCancel
        on_change  => $args{on_change},   # sub() -> notifica a la UI

        play_interval_ms  => $args{play_interval_ms}  // 200,
        fast_forward_step => $args{fast_forward_step} // 5,

        _active   => 0,
        _playing  => 0,
        _fast     => 0,
        _ts       => undef,
        _after_id => undef,   # id del after pendiente (para poder cancelarlo)
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# Consultas de estado (para que la UI sincronice botones/labels)
# -----------------------------------------------------------------------------
sub is_active  { return $_[0]->{_active}  ? 1 : 0; }
sub is_playing { return $_[0]->{_playing} ? 1 : 0; }
sub is_fast    { return $_[0]->{_fast}    ? 1 : 0; }
sub current_ts { return $_[0]->{_ts}; }

# -----------------------------------------------------------------------------
# start($ts)
# Activa el modo replay con el puntero en el timestamp dado. No necesita
# coincidir exactamente con una vela: la frontera se ancla a la vela mas
# reciente con ts <= $ts (ver _effective_last_index en MarketData).
# Fuerza rebuild completo, ya que no hay estado previo de indicadores
# que se pueda asumir valido para este punto de partida.
# -----------------------------------------------------------------------------
sub start {
    my ($self, $ts) = @_;
    return unless defined $ts;

    $self->_cancel_tick;   # mata cualquier tick en curso antes de reposicionar
    $self->{_active}  = 1;
    $self->{_playing} = 0;
    $self->{_fast}    = 0;

    $self->{market}->set_replay_boundary($ts);
    $self->_full_rebuild;
    $self->{_ts} = $self->{market}->get_replay_boundary;

    $self->_notify;
}

# -----------------------------------------------------------------------------
# step_forward($n)
# Avanza $n velas (default 1) de la temporalidad ACTIVA, una por una,
# alimentando incrementalmente los indicadores. Se detiene sola al
# llegar al final de los datos crudos disponibles (auto-pausa si estaba
# en Play/Fast Forward).
# -----------------------------------------------------------------------------
sub step_forward {
    my ($self, $n) = @_;
    $n //= 1;
    return unless $self->{_active};

    my $market   = $self->{market};
    my $raw_last = $market->raw_last_index;
    my $cur_idx  = $market->last_index;

    return if $cur_idx >= $raw_last;   # ya estamos al final

    my $target = $cur_idx + $n;
    $target = $raw_last if $target > $raw_last;

    for my $idx ( ($cur_idx + 1) .. $target ) {
        my $c = $market->raw_get_candle($idx);
        $market->set_replay_boundary($c->{ts});
        $self->{indicators}->update_last($market) if $self->{indicators};
    }

    $self->{_ts} = $market->get_replay_boundary;
    $self->_auto_pause_if_at_end;
    $self->_notify;
}

# -----------------------------------------------------------------------------
# step_backward($n)
# Retrocede $n velas (default 1). SIEMPRE rebuild completo (ver nota de
# politica de recalculo en la cabecera del archivo).
# -----------------------------------------------------------------------------
sub step_backward {
    my ($self, $n) = @_;
    $n //= 1;
    return unless $self->{_active};

    my $market  = $self->{market};
    my $cur_idx = $market->last_index;
    return if $cur_idx <= 0;   # ya estamos en la primera vela visible

    my $target = $cur_idx - $n;
    $target = 0 if $target < 0;

    my $c = $market->raw_get_candle($target);
    $market->set_replay_boundary($c->{ts});
    $self->_full_rebuild;
    $self->{_ts} = $market->get_replay_boundary;

    $self->_notify;
}

# -----------------------------------------------------------------------------
# play / fast_forward / pause
# Play normal SIEMPRE resetea el modo rapido (si se venia de Fast
# Forward y se presiona Play, vuelve a 1x). pause() detiene cualquiera
# de los dos sin distincion.
# -----------------------------------------------------------------------------
sub play {
    my ($self) = @_;
    return unless $self->{_active};
    $self->{_fast} = 0;
    return if $self->{_playing};
    $self->{_playing} = 1;
    $self->_notify;
    $self->_schedule_tick;
}

sub fast_forward {
    my ($self) = @_;
    return unless $self->{_active};
    $self->{_fast} = 1;
    return if $self->{_playing};
    $self->{_playing} = 1;
    $self->_notify;
    $self->_schedule_tick;
}

sub pause {
    my ($self) = @_;
    return unless $self->{_playing};
    $self->{_playing} = 0;
    $self->_cancel_tick;   # cancela el after pendiente (spec 24)
    $self->_notify;
}

# -----------------------------------------------------------------------------
# _schedule_tick (privado)
# Programa el siguiente paso automatico via el callback "schedule"
# inyectado (en produccion, un wrapper sobre $canvas->after). Si
# _playing se apago durante la espera (pause, o auto-pausa por fin de
# datos), no se vuelve a reprogramar -- el ciclo se detiene solo.
# -----------------------------------------------------------------------------
sub _schedule_tick {
    my ($self) = @_;
    return unless $self->{_playing};
    return unless $self->{schedule};

    # Guardar el id del after para poder cancelarlo (evita ticks duplicados si
    # se pausa/sale/reposiciona mientras hay uno pendiente). Solo hay un tick
    # pendiente a la vez: la cadena es estrictamente secuencial.
    $self->{_after_id} = $self->{schedule}->( $self->{play_interval_ms}, sub {
        $self->{_after_id} = undef;
        return unless $self->{_playing};
        my $step_n = $self->{_fast} ? $self->{fast_forward_step} : 1;
        $self->step_forward($step_n);
        $self->_schedule_tick if $self->{_playing};
    });
}

# -----------------------------------------------------------------------------
# _cancel_tick (privado): cancela el after pendiente via el callback inyectado
# (en produccion, $canvas->afterCancel). Idempotente. Es la contraparte del
# schedule y la clave para que Pause/Exit/Start no dejen timers colgados que
# sigan avanzando el replay "por su cuenta" (spec 24).
# -----------------------------------------------------------------------------
sub _cancel_tick {
    my ($self) = @_;
    return unless defined $self->{_after_id};
    $self->{cancel}->( $self->{_after_id} ) if $self->{cancel};
    $self->{_after_id} = undef;
}

sub _auto_pause_if_at_end {
    my ($self) = @_;
    my $market = $self->{market};
    if ($market->last_index >= $market->raw_last_index) {
        $self->{_playing} = 0;
        $self->{_fast}    = 0;
    }
}

# -----------------------------------------------------------------------------
# exit_replay
# Vuelve exactamente al estado "en vivo" de Fase 1: limpia la frontera
# y rebuildea los indicadores con TODO el dataset disponible.
# -----------------------------------------------------------------------------
sub exit_replay {
    my ($self) = @_;
    $self->_cancel_tick;   # detener cualquier tick pendiente antes de salir

    # OPTIMIZACION (spec 17): al salir NO se reconstruye todo desde cero. El
    # estado de los indicadores ya es valido para 0..puntero_actual; solo faltan
    # las velas puntero+1..final. Se alimentan INCREMENTALMENTE (igual que un
    # step_forward hasta el final) y luego se limpia la frontera. Esto evita el
    # reset_all + rebuild_all completo (varios segundos en datasets grandes).
    my $market = $self->{market};
    if ( $self->{_active} && $self->{indicators} ) {
        my $raw_last = $market->raw_last_index;
        my $cur_idx  = $market->last_index;
        for my $idx ( ( $cur_idx + 1 ) .. $raw_last ) {
            my $c = $market->raw_get_candle($idx);
            $market->set_replay_boundary( $c->{ts} );
            $self->{indicators}->update_last($market);
        }
    }

    $self->{_playing} = 0;
    $self->{_active}  = 0;
    $self->{_fast}    = 0;
    $self->{_ts}      = undef;

    $market->clear_replay_boundary;
    $self->_notify;
}

# -----------------------------------------------------------------------------
# _full_rebuild (privado)
# -----------------------------------------------------------------------------
sub _full_rebuild {
    my ($self) = @_;
    return unless $self->{indicators};
    $self->{indicators}->reset_all;
    $self->{indicators}->rebuild_all($self->{market});
}

sub _notify {
    my ($self) = @_;
    $self->{on_change}->() if $self->{on_change};
}

1;