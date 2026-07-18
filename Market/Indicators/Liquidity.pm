package Market::Indicators::Liquidity;

# =============================================================================
# Market::Indicators::Liquidity   (Tabla 1 del PDF)
#
# Calculo de Swing Points (High/Low), niveles de liquidez BSL/SSL, pares
# EQH/EQL y la maquina de estados Sweep/Grab/Run. NO dibuja nada (eso es
# Overlays/Liquidity.pm). Contrato IndicatorManager (igual que ATR.pm):
#   - update_at_index($market_data, $i)
#   - update_last($market_data)
#   - get_values()
#   - reset()
#
# Contrato adicional consumido por Overlays/Liquidity.pm e
# Indicators/SMC_Structures.pm:
#   get_swings()       -> [ {id,index,ts,price,kind:'H'|'L'}, ... ]
#   get_levels()       -> [ {id,side:'buy'|'sell',price,index,ts,state,
#                             classification,swept_at_index,
#                             resolved_at_index,consumed_ts,origin_tf,
#                             volumes:{'1m'=>N,'5m'=>N,'15m'=>N}}, ... ]
#     ts          = timestamp de ORIGEN del nivel (vela del swing que lo creo).
#     index       = indice logico de origen en la TF activa.
#     state       = DETECTED(Activo) -> SWEPT -> RESOLVED(Consumido).
#     consumed_ts = timestamp de la vela en que el nivel dejo de ser "resting"
#                   (transicion DETECTED->SWEPT); undef mientras siga Activo.
#     classification = evento que lo consumio (GRAB/SWEEP/RUN), lo fija la
#                   maquina de estados en la fase de eventos.
#   get_equals()       -> [ {kind:'EQH'|'EQL', side:'buy'|'sell',
#                             points:[{index,ts,price},...], price, level,
#                             last_index}, ... ]
#     GRUPO/cluster de swings iguales (>=2 toques). 'points' conserva el
#     timestamp de TODOS sus toques. 'price' = precio representativo (extremo:
#     max de highs para EQH, min de lows para EQL) = nivel de consumo del grupo.
#     'side' liga la zona a BSL(buy)/SSL(sell) que refuerza. 'level' = ref al
#     nivel del toque extremo: el grupo esta ACTIVO mientras level.state eq
#     'DETECTED' y CONSUMIDO (con level.consumed_ts) cuando ese nivel es barrido.
#   get_events()       -> [ {type:'SWEEP'|'GRAB'|'RUN', dir:'up'|'down',
#                             index, price, label, level_id, side:'buy'|'sell',
#                             break_ts, confirmed_ts, extreme, confirm_bars},...]
#     level_id = id ESTABLE de la interaccion (un nivel -> un solo evento).
#     index/confirmed_ts = vela de CONFIRMACION ; break_ts = vela de ruptura.
#     extreme = extremo alcanzado ; confirm_bars = velas usadas para confirmar.
#   last_swing_high()  -> {index,price,...} | undef
#   last_swing_low()   -> {index,price,...} | undef
#   side_label($side)  -> 'BSL' | 'SSL'
#   is_internal($level,$current_tf) -> 1|0  (ver nota de alcance Etapa 6)
#
# ETAPA 6 (peso de volumen multi-temporal + Interna/Externa):
#   Cada nivel almacena, ademas, el volumen 1m/5m/15m observado durante la
#   ventana [ts,ts+interval) de su vela de origen, en la TF que estaba
#   activa al crearse (origin_tf). NOTA DE ALCANCE: con la arquitectura
#   actual (una sola instancia de Liquidity viva por TF -- cualquier cambio
#   de TF dispara reset_all+rebuild_all desde cero) NUNCA puede existir un
#   nivel "Externo" en sentido estricto: is_internal() siempre devolvera 1
#   en esta entrega. La coexistencia real multi-TF (necesaria para que
#   "Externa" tenga un caso real) se reserva para la 2a entrega.
#
# GARANTIA DE NO-FUGA DE FUTURO:
#   - Swings: un swing en el indice c con profundidad k SOLO es
#     matematicamente confirmable cuando existen las k velas posteriores
#     (c+1..c+k). Este indicador evalua, al recibir la vela visible con
#     indice i, el CANDIDATO c = i - k (nunca la vela i misma). El swing
#     se registra exactamente en el instante en que i = c+k se vuelve
#     visible -- nunca antes. No hay verificacion adicional de replay:
#     la seguridad es consecuencia directa de la definicion del swing.
#   - Maquina de estados (Sweep/Swept/Reclaimed/Acceptance/Resolved):
#     evalua SOLO con la vela actualmente visible y el historial de
#     velas ya procesadas (swept_at_index, contador de velas desde el
#     sweep) -- nunca necesita mirar hacia adelante, por lo que no
#     requiere ningun retraso adicional.
#
# EQH/EQL: dos swings del MISMO tipo (H/H o L/L) se consideran "iguales"
# si |precio_1 - precio_2| <= ATR(en el indice del swing mas reciente)
# * eq_factor (0.10 por defecto).
#
# Maquina de estados (5 estados, autoridad = Especificacion 2a Fase, seccion
# 4.2-4.3) -- clasificacion EXCLUSIVA (un solo resultado por nivel), confirmada
# AL CIERRE de la vela y SIN informacion futura. n_since = velas DESDE Y CON la
# ruptura (la vela que rompe es n_since=1).
#   1) DETECTED  : nivel identificado (Swing High/Low o EQH/EQL), en reposo.
#   2) SWEPT     : ruptura INTRABAR del extremo. High > BSL o Low < SSL. Como
#                  los precios de NQ son multiplos de 0.25, la ruptura estricta
#                  ya "considera el tick minimo" (>= 1 tick). Registra el ts de
#                  ruptura (consumed_ts) y el extremo inicial.
#   3) ACCEPTANCE: tras SWEPT el precio ACEPTA fuera del nivel (cierres estrictos
#                  fuera, sin recuperar). Estado transitorio mientras se cuentan
#                  las N velas.
#   4) RECLAIMED : tras SWEPT el precio RECUPERA (cierra de vuelta dentro del
#                  rango). Estado transitorio previo a la resolucion Sweep/Grab.
#   5) RESOLVED  : ciclo terminal con clasificacion inmutable. resolved_via
#                  guarda la rama (RECLAIMED|ACCEPTANCE).
#
# PRIORIDAD (decision documentada ante el solape Sweep/Grab de la spec): el
# RECLAMO (recuperacion) se evalua ANTES que la aceptacion (Run), de modo que
# una interaccion NUNCA es Grab+Sweep+Run a la vez:
#     * reclamo en n_since == 1 (la MISMA vela que rompio, "cierre dentro
#       estandar")                                       -> SWEEP  (Reclaimed)
#     * reclamo en 2 <= n_since <= grab_window (=3, "retorno y rechazo en un
#       maximo de 3 velas posteriores a la penetracion") -> GRAB   (Reclaimed)
#     * SIN reclamo y n_since >= acceptance_n (=3 cierres consecutivos estrictos
#       fuera, "expansion con aceptacion")               -> RUN    (Acceptance)
# Con N=3 para Run, todo nivel SWEPT resuelve a mas tardar en n_since=3, lo que
# FUERZA que Sweep(=n1) y Grab(=n2..3) sean los unicos rangos no vacios y
# mutuamente excluyentes. Defaults: grab_window=3, acceptance_n=3 (ambos segun
# la spec). (continuation_window quedo OBSOLETO.)
# =============================================================================

use strict;
use warnings;

# Tick minimo del E-mini Nasdaq (NQ) = 0.25 (mismo valor que ChartEngine::
# PRICE_TICK). Sirve de PISO a la tolerancia EQH/EQL: la comparacion de precios
# "iguales" nunca es mas estricta que la propia granularidad del mercado.
use constant NQ_TICK => 0.25;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        k              => $args{k}              // 3,
        eq_factor      => $args{eq_factor}      // 0.10,
        eq_lookback    => $args{eq_lookback}    // 50,
        max_open_levels => $args{max_open_levels} // 150,
        track_volume    => defined $args{track_volume} ? $args{track_volume} : 1,
        # Autoridad = Especificacion 2a Fase (4.2-4.3): Grab = reclamo en un
        # MAXIMO de 3 velas posteriores a la penetracion (grab_window=3);
        # Sweep = reclamo en la MISMA vela (n_since==1); Run = N=3 cierres
        # consecutivos fuera (acceptance_n=3). Ambos parametros configurables.
        grab_window  => $args{grab_window}  // 3,
        acceptance_n => $args{acceptance_n} // 3,
        # OBSOLETO: se conserva por compatibilidad de constructor, pero la
        # maquina de estados ya NO lo usa. Reclasificar un reclamo YA confirmado
        # (Grab/Sweep) como Run mediante una ventana de continuacion contradice
        # la spec ("Grab/Sweep se confirma al reclamo y se excluye de Run").
        continuation_window => $args{continuation_window} // 3,
        atr_factor   => $args{atr_factor}   // 0.30,
        atr          => $args{atr},   # referencia DIRECTA al objeto ATR

        swings => [],   # todos los swings confirmados, en orden de confirmacion
        levels => [],   # TODOS los niveles (cualquier estado), en orden de creacion
        equals => [],   # pares EQH/EQL (puramente geometrico, no es un "nivel")
        events => [],   # eventos Sweep/Grab/Run ya resueltos

        _open_level_refs      => [],   # niveles en DETECTED o SWEPT (working set)
        _next_id               => 1,
        _last_evaluated_index  => -1,  # ultimo candidato de swing ya evaluado
        _market_data           => undef,  # ref al MarketData (para get_market_data)

        # Agregados del working set para el FAST-SKIP de la maquina de estados
        # (ver _update_state_machine). Permiten saltar en O(1) las velas en las
        # que ningun nivel puede transicionar, sin recorrer los ~150 niveles.
        _ws_dirty    => 1,      # los agregados necesitan recomputo
        _ws_min_buy  => 9e18,   # menor precio entre DETECTED buy  (+inf si no hay)
        _ws_max_sell => -9e18,  # mayor precio entre DETECTED sell (-inf si no hay)
        _ws_active   => 0,      # nº de niveles SWEPT pendientes de resolver
    };

    die "Market::Indicators::Liquidity: grab_window y acceptance_n deben ser >= 1"
      if $self->{grab_window} < 1 || $self->{acceptance_n} < 1;

    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# reset
# -----------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{levels} = [];
    $self->{equals} = [];
    $self->{events} = [];
    $self->{_open_level_refs}     = [];
    $self->{_next_id}             = 1;
    $self->{_last_evaluated_index} = -1;
    $self->{_ws_dirty}    = 1;
    $self->{_ws_min_buy}  = 9e18;
    $self->{_ws_max_sell} = -9e18;
    $self->{_ws_active}   = 0;
    $self->{_market_data} = undef;
}

# -----------------------------------------------------------------------------
# Accesores de solo lectura
# -----------------------------------------------------------------------------
sub get_values { return $_[0]->{levels}; }
sub get_swings { return $_[0]->{swings}; }
sub get_levels { return $_[0]->{levels}; }
sub get_equals { return $_[0]->{equals}; }
sub get_events { return $_[0]->{events}; }
# Ref al MarketData de la ultima pasada. La usa Overlays/Liquidity para no
# dibujar lineas resting mas alla de la ultima vela real (mismo patron que
# Indicators::ZigZag::get_market_data). Consciente de la frontera de replay.
sub get_market_data { return $_[0]->{_market_data}; }

sub last_swing_high {
    my ($self) = @_;
    for my $sw ( reverse @{ $self->{swings} } ) {
        return $sw if $sw->{kind} eq 'H';
    }
    return undef;
}

sub last_swing_low {
    my ($self) = @_;
    for my $sw ( reverse @{ $self->{swings} } ) {
        return $sw if $sw->{kind} eq 'L';
    }
    return undef;
}

sub side_label {
    my ( $self, $side ) = @_;
    return $side eq 'buy' ? 'BSL' : 'SSL';
}

# -----------------------------------------------------------------------------
# update_last (streaming / replay incremental)
# -----------------------------------------------------------------------------
sub update_last {
    my ( $self, $market_data ) = @_;
    my $idx = $market_data->last_index;
    return if $idx < 0;
    $self->update_at_index( $market_data, $idx );
}

# -----------------------------------------------------------------------------
# update_at_index (rebuild / cada vela nueva visible)
# Orden: (1) maquina de estados sobre niveles ya abiertos, usando la vela
# $i directamente; (2) deteccion de swing en el candidato c=i-k. El orden
# es seguro en ambos sentidos: un nivel recien creado en (2) no puede ser
# barrido por su propia vela de confirmacion (ya se verifico que esa vela
# NO supera el nivel, es parte de la propia definicion de swing), asi que
# no importa si (2) ocurriera antes de (1).
# -----------------------------------------------------------------------------
sub update_at_index {
    my ( $self, $market_data, $i ) = @_;
    $self->{_market_data} = $market_data;

    $self->_update_state_machine( $market_data, $i );

    my $k = $self->{k};
    my $c = $i - $k;
    return if $c < $k;
    return if $c <= $self->{_last_evaluated_index};

    $self->_evaluate_swing_candidate( $market_data, $c, $k );
    $self->{_last_evaluated_index} = $c;
}

# =============================================================================
# SWING POINTS / EQH-EQL
# =============================================================================

# -----------------------------------------------------------------------------
# _evaluate_swing_candidate (privado)
# High[c] > High[c-k..c-1] y High[c] > High[c+1..c+k] (estrictamente mayor
# que TODAS, no solo el maximo) -- analogo para Low.
# -----------------------------------------------------------------------------
sub _evaluate_swing_candidate {
    my ( $self, $market_data, $c, $k ) = @_;

    my $candle = $market_data->get_candle($c);
    return unless $candle;

    my ( $is_high, $is_low ) = ( 1, 1 );
    for my $j ( ( $c - $k ) .. ( $c + $k ) ) {
        next if $j == $c;
        my $other = $market_data->get_candle($j);
        return unless $other;   # defensivo: no deberia faltar en este rango

        $is_high = 0 if $other->{high} >= $candle->{high};
        $is_low  = 0 if $other->{low}  <= $candle->{low};
        last if !$is_high && !$is_low;
    }

    # ---- Filtro de prominencia por ATR ----
    # Un swing es significativo si su "altura" sobre el contexto supera
    # atr_factor * ATR[c]. Elimina swings minusculos en rangos laterales
    # que generan etiquetas de liquidez ruidosas.
    if ($is_high || $is_low) {
        my $atr_vals = $self->{atr} ? $self->{atr}->get_values : undef;
        my $atr_val  = ($atr_vals && defined $atr_vals->[$c]) ? $atr_vals->[$c] : 0;
        my $min_prom = $atr_val * $self->{atr_factor};

        if ($is_high && $min_prom > 0) {
            my $ctx_low = $candle->{low};
            for my $j (($c - $k) .. ($c + $k)) {
                my $o = $market_data->get_candle($j) or next;
                $ctx_low = $o->{low} if $o->{low} < $ctx_low;
            }
            $is_high = 0 if ($candle->{high} - $ctx_low) < $min_prom;
        }
        if ($is_low && $min_prom > 0) {
            my $ctx_high = $candle->{high};
            for my $j (($c - $k) .. ($c + $k)) {
                my $o = $market_data->get_candle($j) or next;
                $ctx_high = $o->{high} if $o->{high} > $ctx_high;
            }
            $is_low = 0 if ($ctx_high - $candle->{low}) < $min_prom;
        }
    }

    $self->_register_swing( 'H', $market_data, $candle, $c ) if $is_high;
    $self->_register_swing( 'L', $market_data, $candle, $c ) if $is_low;
}

# -----------------------------------------------------------------------------
# _register_swing (privado)
# -----------------------------------------------------------------------------
sub _register_swing {
    my ( $self, $kind, $market_data, $candle, $idx ) = @_;

    my $swing = {
        id    => $self->{_next_id}++,
        kind  => $kind,   # 'H' | 'L'
        index => $idx,
        ts    => $candle->{ts},
        price => ( $kind eq 'H' ? $candle->{high} : $candle->{low} ),
    };
    push @{ $self->{swings} }, $swing;

    my $level = $self->_register_level( $kind, $swing, $market_data );

    # Back-ref swing -> su nivel (NO es un pivote nuevo: es el mismo swing).
    # Lo usa el agrupador EQH/EQL para derivar el consumo de un grupo del estado
    # del nivel de su toque extremo, sin re-escanear velas. (level->origin_swing_id
    # apunta de vuelta por id, no por ref: no hay ciclo de referencias.)
    $swing->{_level} = $level;

    # ---- Working set: TODO nivel entra (ciclo de vida determinista) ----
    # Cada swing confirmado aporta EXACTAMENTE un nivel (Req 3: no hay duplicado
    # por el mismo origen). Ese nivel entra SIEMPRE al working set para que su
    # ciclo de vida Activo(DETECTED) -> Consumido(SWEPT) sea DETERMINISTA (Req 6):
    # ningun nivel queda fuera del escaneo de la maquina de estados y, por tanto,
    # sin posibilidad de consumirse ni de retirarse de las lineas "resting".
    #
    # NOTA: antes se descartaba del working set un nivel casi-identico (mismo lado
    # y |dp| <= 2*eq_factor*ATR de otro nivel abierto). Eso dejaba ese nivel en
    # estado DETECTED PERMANENTE (nunca barrido) -> linea BSL/SSL colgada que no
    # respetaba el ciclo de vida. La de-duplicacion VISUAL de niveles casi
    # iguales corresponde a la capa de render (clustering del overlay), no a
    # ocultar niveles en el calculo.
    push @{ $self->{_open_level_refs} }, $level;

    # Cap del working set: los niveles DETECTED muy antiguos (lejos en el
    # tiempo) casi nunca se barren y solo encarecen el escaneo por vela. Se
    # conservan los mas recientes (los SWEPT se resuelven en pocas velas, asi
    # que quedan al final; el frente son DETECTED viejos). Escaneo acotado a
    # max_open_levels por vela en vez de O(n) creciente.
    my $refs = $self->{_open_level_refs};
    if ( @$refs > $self->{max_open_levels} ) {
        splice( @$refs, 0, @$refs - $self->{max_open_levels} );
    }

    # El working set cambio (nuevo nivel / cap): los agregados del fast-skip
    # deben recomputarse antes de la proxima evaluacion de la maquina de estados.
    $self->{_ws_dirty} = 1;

    $self->_check_equal_levels( $kind, $swing, $level );
}

# -----------------------------------------------------------------------------
# _register_level (privado)
# side 'buy' = BSL (de un swing high) | 'sell' = SSL (de un swing low).
# Nace en estado DETECTED (Estado 1 del diagrama del PDF).
# -----------------------------------------------------------------------------
sub _register_level {
    my ( $self, $kind, $swing, $market_data ) = @_;

    my $level = {
        id                => $self->{_next_id}++,
        side              => ( $kind eq 'H' ? 'buy' : 'sell' ),
        price             => $swing->{price},
        index             => $swing->{index},
        ts                => $swing->{ts},      # timestamp de ORIGEN (Req 4)
        origin_swing_id   => $swing->{id},
        state             => 'DETECTED',        # 1) Activo
        classification    => undef,             # GRAB|SWEEP|RUN (al resolver)
        resolved_via      => undef,             # RECLAIMED|ACCEPTANCE (rama del estado 5)
        swept_at_index    => undef,
        resolved_at_index => undef,
        consumed_ts       => undef,             # timestamp de RUPTURA (DETECTED->SWEPT)
        extreme           => undef,             # extremo alcanzado tras la ruptura
        confirmed_ts      => undef,             # timestamp de CONFIRMACION del evento
        confirm_bars      => undef,             # velas usadas para confirmar (n_since)

        # Interna/Externa (4.4): 'internal' = originada en la TF activa;
        # 'external' = proyectada desde una HTF (se fija en _attach_multi_tf_volume).
        origin            => undef,
        eq_group          => undef,             # ref al grupo EQH/EQL si el nivel participa

        # Etapa 6 (Fase 2): pesado de volumen multi-temporal + origen de TF.
        # volumes: volumen 1m/5m/15m observado en la ventana de la vela de origen.
        # volumes_complete: 1 = desglose valido (sub-TF encaja en la ventana);
        # 0 = incompleto/degenerado (volumen = undef, NUNCA 0-como-real).
        origin_tf        => undef,
        volumes          => { '1m' => 0, '5m' => 0, '15m' => 0 },
        volumes_complete => { '1m' => 0, '5m' => 0, '15m' => 0 },
    };

    $self->_attach_multi_tf_volume( $level, $swing, $market_data )
        if $market_data && $self->{track_volume};

    push @{ $self->{levels} }, $level;
    return $level;
}

# -----------------------------------------------------------------------------
# _attach_multi_tf_volume (privado) -- Etapa 6, Fase 2
# Calcula y almacena en el nivel el volumen observado en 1m/5m/15m durante
# la ventana [ts, ts+interval) de la vela "macro" (TF activa al momento de
# crear el nivel), independientemente de cual sea esa TF activa. Tambien
# registra origin_tf (infraestructura para Interna/Externa -- ver nota de
# alcance en la cabecera del archivo).
#
# NOTA: si la TF activa es 1m/5m/15m, el calculo sigue siendo correcto pero
# parcialmente degenerado (alguna de las 3 sub-temporalidades puede no
# "encajar" una vela completa dentro de una ventana mas angosta que su
# propio ancho de bucket -- ver MarketData::sum_volume_for_tf_window). No es
# un error: es la consecuencia matematica de pedir un desglose mas fino que
# el ancho de la propia ventana.
# -----------------------------------------------------------------------------
sub _attach_multi_tf_volume {
    my ( $self, $level, $swing, $market_data ) = @_;

    my $tf = $market_data->get_timeframe;
    $level->{origin_tf} = $tf;
    # Interna vs Externa (4.4): en esta arquitectura vive UNA sola instancia de
    # Liquidity por TF (un cambio de TF dispara reset+rebuild), asi que todo
    # nivel nace en la TF ACTIVA => 'internal'. El metodo is_internal() y este
    # campo quedan listos para niveles proyectados desde HTF ('external') cuando
    # exista coexistencia real multi-TF, sin adelantar la confirmacion HTF.
    $level->{origin} = 'internal';

    my $active_iv = $self->_tf_seconds( $market_data, $tf );
    return unless defined $active_iv;   # TF sin intervalo conocido: sin volumen

    my $ts_start = $swing->{ts};
    my $ts_end   = $ts_start + $active_iv;

    for my $sub_tf ( '1m', '5m', '15m' ) {
        my $sub_iv = $self->_tf_seconds( $market_data, $sub_tf );
        # COMPLETO solo si la sub-TF ENCAJA en la ventana de la vela de origen
        # (sub_iv <= active_iv). Si es mas gruesa que la ventana, el desglose es
        # DEGENERADO: se marca incompleto y el volumen queda UNDEF -- nunca 0,
        # que se reservaria para "sin trades reales" en una ventana valida. La
        # trazabilidad del origen queda en origin_tf + volumes_complete.
        if ( defined $sub_iv && $sub_iv <= $active_iv ) {
            $level->{volumes}{$sub_tf} =
                $market_data->sum_volume_for_tf_window( $sub_tf, $ts_start, $ts_end );
            $level->{volumes_complete}{$sub_tf} = 1;
        }
        else {
            $level->{volumes}{$sub_tf}          = undef;   # incompleto (NO 0)
            $level->{volumes_complete}{$sub_tf} = 0;
        }
    }
}

# -----------------------------------------------------------------------------
# _tf_seconds (privado): intervalo en segundos de una TF, incluyendo '1m' (que
# MarketData::tf_interval_seconds no cubre por ser la base del feed).
# -----------------------------------------------------------------------------
sub _tf_seconds {
    my ( $self, $market_data, $tf ) = @_;
    return 60 if defined $tf && $tf eq '1m';
    return $market_data->tf_interval_seconds($tf);
}

# -----------------------------------------------------------------------------
# is_internal (Etapa 6, Fase 2)
# Compara el origin_tf del nivel contra la TF actualmente activa. Con la
# arquitectura actual (una sola instancia de Liquidity viva por TF, ver nota
# de alcance en la cabecera) esto sera SIEMPRE 1 (todo nivel vigente fue
# creado en la TF que esta activa ahora, porque cualquier cambio de TF
# reconstruye el indicador desde cero). El campo y el metodo quedan listos
# para cuando exista coexistencia real multi-TF (2a entrega).
# -----------------------------------------------------------------------------
sub is_internal {
    my ( $self, $level, $current_tf ) = @_;
    return 1 unless defined $level->{origin_tf};
    return $level->{origin_tf} eq $current_tf ? 1 : 0;
}

# -----------------------------------------------------------------------------
# _check_equal_levels (privado) -- AGRUPADOR EQH/EQL (grupo/cluster, no pares)
#
# Se llama SOLO cuando un swing acaba de CONFIRMARSE (en _register_swing), de
# modo que un grupo nunca nace antes de que su SEGUNDO pivote este confirmado
# (sin uso de futuro). Reutiliza los swings confirmados existentes; NO crea una
# segunda lista de pivotes.
#
# Tolerancia DETERMINISTA (reutiliza la config del proyecto): eq_factor * ATR
# (misma base ATR que la prominencia), con PISO de 1 tick de NQ. Nunca compara
# con '=='. Como los precios de NQ son multiplos de 0.25, |dp| ya es multiplo
# del tick; el piso garantiza que la tolerancia respete el tick minimo.
#
# CICLO DE VIDA del grupo:
#   - creacion       : 2o pivote igual confirmado y aun ACTIVO (nivel DETECTED).
#   - nuevos toques  : un 3er/4o pivote igual dentro de tolerancia se AGREGA al
#                      grupo activo (no crea uno nuevo) -> sin duplicar zonas.
#   - precio rep.    : extremo del cluster (max highs EQH / min lows EQL); su
#                      nivel gobierna el consumo.
#   - activo/consumo : DERIVADO del nivel del toque extremo (level.state /
#                      level.consumed_ts) -> se reconstruye igual en Replay y no
#                      toca la maquina Sweep/Grab/Run.
# -----------------------------------------------------------------------------
sub _check_equal_levels {
    my ( $self, $kind, $new_swing, $new_level ) = @_;
    return unless $self->{atr};

    my $atr_values = $self->{atr}->get_values;
    return unless $atr_values && @$atr_values;
    my $atr_at_new = $atr_values->[ $new_swing->{index} ];
    return unless defined $atr_at_new;

    # Tolerancia = eq_factor*ATR con piso de 1 tick NQ (considera el tick minimo).
    my $tolerance = $self->{eq_factor} * $atr_at_new;
    $tolerance = NQ_TICK if $tolerance < NQ_TICK;

    my $is_high   = ( $kind eq 'H' );
    my $eq_kind   = $is_high ? 'EQH' : 'EQL';
    my $side      = $is_high ? 'buy' : 'sell';   # EQH refuerza BSL, EQL SSL
    my $new_price = $new_swing->{price};
    my $new_point = {
        index => $new_swing->{index},
        ts    => $new_swing->{ts},
        price => $new_price,
    };

    my $equals   = $self->{equals};
    my $lookback = $self->{eq_lookback};

    # (1) INCORPORAR el nuevo toque a un grupo ACTIVO del mismo tipo cuyo precio
    #     representativo caiga dentro de tolerancia (NO crea grupo nuevo).
    my $gstop = $#$equals - $lookback;
    $gstop = 0 if $gstop < 0;
    for ( my $g = $#$equals; $g >= $gstop; $g-- ) {
        my $grp = $equals->[$g];
        next unless $grp->{kind} eq $eq_kind;
        next unless $grp->{level} && $grp->{level}{state} eq 'DETECTED';  # ACTIVO
        next if abs( $grp->{price} - $new_price ) > $tolerance;

        push @{ $grp->{points} }, $new_point;
        $grp->{last_index} = $new_swing->{index};
        $new_level->{eq_group} = $grp;   # referencia EQH/EQL del nivel que toca
        # el extremo gobierna el precio representativo y el nivel de consumo
        if ( $is_high ? ( $new_price > $grp->{price} )
                      : ( $new_price < $grp->{price} ) ) {
            $grp->{price} = $new_price;
            $grp->{level} = $new_level;
        }
        return;
    }

    # (2) CREAR un grupo nuevo con el swing previo mas cercano del mismo tipo,
    #     dentro de tolerancia y AUN ACTIVO (nivel DETECTED = liquidez en reposo).
    my $swings = $self->{swings};
    my $sstop  = $#$swings - $lookback;
    $sstop = 0 if $sstop < 0;
    for ( my $j = $#$swings; $j >= $sstop; $j-- ) {
        my $prev = $swings->[$j];
        next if $prev->{id} == $new_swing->{id};
        next unless $prev->{kind} eq $kind;
        next unless $prev->{_level} && $prev->{_level}{state} eq 'DETECTED';
        next if abs( $prev->{price} - $new_price ) > $tolerance;

        my $prev_extreme = $is_high ? ( $prev->{price} > $new_price )
                                    : ( $prev->{price} < $new_price );
        my $grp = {
            kind       => $eq_kind,
            side       => $side,
            points     => [
                { index => $prev->{index}, ts => $prev->{ts}, price => $prev->{price} },
                $new_point,
            ],
            price      => $prev_extreme ? $prev->{price}  : $new_price,
            level      => $prev_extreme ? $prev->{_level} : $new_level,
            last_index => $new_swing->{index},
        };
        push @$equals, $grp;
        # referencia EQH/EQL en AMBOS niveles del par (cuando existan)
        $new_level->{eq_group}     = $grp;
        $prev->{_level}{eq_group}  = $grp if $prev->{_level};
        return;
    }
}

# =============================================================================
# MAQUINA DE ESTADOS: Detected -> Swept -> (Acceptance|Reclaimed) -> Resolved
# =============================================================================

# La logica de sweep (Detected->Swept) y de resolucion (Swept->Grab/Sweep/Run)
# esta INLINE en el bucle por rendimiento: se evalua una vez por nivel abierto
# y por vela (millones de veces en datasets grandes), y evitar el coste de la
# llamada a metodo por iteracion reduce drasticamente el tiempo de rebuild
# (arranque de la app y entrada/salida de replay). El comportamiento es
# identico al de los antiguos _check_sweep/_check_resolution.
sub _update_state_machine {
    my ( $self, $market_data, $i ) = @_;
    my $candle = $market_data->get_candle($i);
    return unless $candle;

    my $ch = $candle->{high};
    my $cl = $candle->{low};

    # Si el working set cambio desde el ultimo escaneo (nuevo nivel / cap),
    # recomputar los agregados que gobiernan el fast-skip.
    $self->_recompute_ws_aggregates if $self->{_ws_dirty};

    # ---- FAST-SKIP (O(1)) ----------------------------------------------------
    # Ningun nivel puede transicionar en esta vela cuando:
    #   * no hay niveles SWEPT pendientes (esos dependen del tiempo y
    #     hay que revisarlos cada vela), y
    #   * el maximo de la vela no supera el DETECTED buy mas bajo (un buy solo
    #     se barre si ch > su precio), y
    #   * el minimo de la vela no perfora el DETECTED sell mas alto (un sell
    #     solo se barre si cl < su precio).
    # En ese caso se evita recorrer los ~150 niveles del working set. Es
    # EXACTAMENTE equivalente al escaneo completo (que no habria producido
    # ninguna transicion ni evento).
    return if $self->{_ws_active} == 0
           && $ch <= $self->{_ws_min_buy}
           && $cl >= $self->{_ws_max_sell};

    my $cc = $candle->{close};
    my $gw = $self->{grab_window};
    my $an = $self->{acceptance_n};

    # Se reconstruye el working set y, en la misma pasada, los agregados del
    # fast-skip segun el estado RESULTANTE de cada nivel.
    my @still_open;
    my $min_buy  = 9e18;
    my $max_sell = -9e18;
    my $active   = 0;
    for my $level ( @{ $self->{_open_level_refs} } ) {
        my $buy = ( $level->{side} eq 'buy' );
        my $price = $level->{price};

        # 1->2  Detected -> Swept (RUPTURA INTRABAR). Ruptura estricta = >= 1 tick
        # (precios NQ en multiplos de 0.25): considera el tick minimo.
        if ( $level->{state} eq 'DETECTED' ) {
            if ( $buy ? ( $ch > $price ) : ( $cl < $price ) ) {
                $level->{state}          = 'SWEPT';
                $level->{swept_at_index} = $i;
                $level->{consumed_ts}    = $candle->{ts};   # timestamp de ruptura
                $level->{extreme}        = $buy ? $ch : $cl;
            }
        }

        # 2->{3,4}->5  Resolucion EXCLUSIVA al cierre, sin futuro. El RECLAMO
        # (recuperacion) tiene PRIORIDAD sobre la aceptacion (Run) -> nunca
        # simultaneos. Se evalua tanto en la vela de la ruptura (n_since=1) como
        # mientras el nivel siga aceptando fuera (ACCEPTANCE).
        if ( $level->{state} eq 'SWEPT' || $level->{state} eq 'ACCEPTANCE' ) {
            # extremo alcanzado durante la interaccion (mecha mas lejana)
            if ($buy) { $level->{extreme} = $ch if $ch > $level->{extreme}; }
            else      { $level->{extreme} = $cl if $cl < $level->{extreme}; }

            my $n_since = $i - $level->{swept_at_index} + 1;
            my $reclaim = $buy ? ( $cc <= $price ) : ( $cc >= $price );

            if ($reclaim) {
                # Estado 4 (Reclaimed): recupero dentro del rango => nunca Run.
                #   n_since==1 (misma vela que rompio) -> SWEEP
                #   2..grab_window (<=3 velas)         -> GRAB
                #   (reclamo mas tardio, no alcanzable con N=3) -> SWEEP estandar
                my $cls = ( $n_since == 1 )  ? 'SWEEP'
                        : ( $n_since <= $gw ) ? 'GRAB'
                        :                       'SWEEP';
                $self->_resolve( $level, $cls, $i, $candle->{ts}, 'RECLAIMED' );
            }
            elsif ( $n_since >= $an ) {
                # Estado 3 (Acceptance): N cierres consecutivos fuera sin
                # recuperacion => RUN. Confirmado en esta vela, sin futuro.
                $self->_resolve( $level, 'RUN', $i, $candle->{ts}, 'ACCEPTANCE' );
            }
            else {
                # Aceptando fuera del nivel, aun sin resolver: Estado 3 en curso.
                $level->{state} = 'ACCEPTANCE';
            }
        }

        next if $level->{state} eq 'RESOLVED';
        push @still_open, $level;

        # Agregados para el fast-skip de la proxima vela, segun estado final.
        if ( $level->{state} eq 'DETECTED' ) {
            if ( $level->{side} eq 'buy' ) {
                $min_buy = $level->{price} if $level->{price} < $min_buy;
            } else {
                $max_sell = $level->{price} if $level->{price} > $max_sell;
            }
        } else {
            $active++;   # SWEPT: siempre revisar la proxima vela
        }
    }
    $self->{_open_level_refs} = \@still_open;
    $self->{_ws_min_buy}  = $min_buy;
    $self->{_ws_max_sell} = $max_sell;
    $self->{_ws_active}   = $active;
    $self->{_ws_dirty}    = 0;
}

# -----------------------------------------------------------------------------
# _recompute_ws_aggregates (privado)
# Recalcula los agregados del working set (menor DETECTED buy, mayor DETECTED
# sell, nº de niveles pendientes) que gobiernan el fast-skip de la maquina de
# estados. Se invoca cuando el working set fue modificado fuera del escaneo
# (alta de nivel / cap), marcado por _ws_dirty.
# -----------------------------------------------------------------------------
sub _recompute_ws_aggregates {
    my ($self) = @_;
    my $min_buy  = 9e18;
    my $max_sell = -9e18;
    my $active   = 0;
    for my $level ( @{ $self->{_open_level_refs} } ) {
        my $st = $level->{state};
        if ( $st eq 'DETECTED' ) {
            if ( $level->{side} eq 'buy' ) {
                $min_buy = $level->{price} if $level->{price} < $min_buy;
            } else {
                $max_sell = $level->{price} if $level->{price} > $max_sell;
            }
        } elsif ( $st ne 'RESOLVED' ) {
            $active++;
        }
    }
    $self->{_ws_min_buy}  = $min_buy;
    $self->{_ws_max_sell} = $max_sell;
    $self->{_ws_active}   = $active;
    $self->{_ws_dirty}    = 0;
}

# -----------------------------------------------------------------------------
# _resolve (privado) -- Estado 5 (Resolved): clasificacion final inmutable
# + emite el evento correspondiente para get_events().
# -----------------------------------------------------------------------------
sub _resolve {
    my ( $self, $level, $classification, $i, $confirm_ts, $via ) = @_;

    $level->{state}             = 'RESOLVED';
    $level->{resolved_via}      = $via;           # RECLAIMED | ACCEPTANCE (estados 3/4)
    $level->{classification}    = $classification;
    $level->{resolved_at_index} = $i;
    $level->{confirmed_ts}      = $confirm_ts;
    $level->{confirm_bars}      = $i - $level->{swept_at_index} + 1;

    my $dir = ( $level->{side} eq 'buy' ) ? 'up' : 'down';
    # Evento con el ESTADO COMPLETO de la interaccion. 'level_id' es el
    # identificador ESTABLE de la interaccion (un nivel -> exactamente un
    # evento terminal: nunca Grab+Sweep+Run sobre el mismo nivel).
    push @{ $self->{events} }, {
        type             => $classification,          # 'SWEEP' | 'GRAB' | 'RUN'
        dir              => $dir,                      # 'up' | 'down'
        index            => $i,                        # vela de CONFIRMACION
        price            => $level->{price},           # precio del nivel
        label            => $self->side_label( $level->{side} ) . ' ' . $classification,
        level_id         => $level->{id},              # id estable de la interaccion
        side             => $level->{side},            # buy=BSL | sell=SSL
        resolved_via     => $via,                      # RECLAIMED | ACCEPTANCE
        break_ts         => $level->{consumed_ts},     # timestamp de ruptura
        confirmed_ts     => $confirm_ts,               # timestamp de confirmacion
        extreme          => $level->{extreme},         # extremo alcanzado
        confirm_bars     => $level->{confirm_bars},    # velas usadas para confirmar
        # Interna/Externa + pesado multi-temporal conservados POR EVENTO (4.4):
        origin           => $level->{origin},          # 'internal' | 'external'
        origin_tf        => $level->{origin_tf},       # trazabilidad de origen
        volumes          => $level->{volumes},         # {1m,5m,15m} (undef si incompleto)
        volumes_complete => $level->{volumes_complete},# {1m,5m,15m} 1|0
        eq_group         => $level->{eq_group},        # ref EQH/EQL si existe
    };
}

1;