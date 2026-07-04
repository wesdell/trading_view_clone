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
#   get_levels()       -> [ {id,side:'buy'|'sell',price,index,state,
#                             classification,swept_at_index,
#                             resolved_at_index,origin_tf,
#                             volumes:{'1m'=>N,'5m'=>N,'15m'=>N}}, ... ]
#   get_equals()       -> [ {kind:'EQH'|'EQL',i1,i2,p1,p2}, ... ]
#   get_events()       -> [ {type:'SWEEP'|'GRAB'|'RUN',dir:'up'|'down',
#                             index,price,label}, ... ]
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
# Maquina de estados (orden de evaluacion en cada vela, sobre niveles
# abiertos):
#   DETECTED  -> SWEPT      : High > nivel (BSL) o Low < nivel (SSL).
#   SWEPT     -> RESOLVED   : evaluado vela por vela desde el sweep
#       (n_since = velas transcurridas DESDE Y CON la vela del sweep):
#         a) cierre vuelve dentro del rango Y n_since <= grab_window
#            -> clasificacion GRAB.
#         b) cierre vuelve dentro del rango Y n_since >  grab_window
#            -> clasificacion SWEEP.
#         c) cierre se mantiene fuera del rango por n_since >=
#            acceptance_n (sin haber vuelto dentro antes)
#            -> clasificacion RUN.
#   IMPORTANTE: acceptance_n DEBE ser > grab_window, o la clasificacion
#   SWEEP (reclamo "estandar", no tan rapido como un Grab) jamas podria
#   ocurrir -- todo se resolveria como GRAB o RUN antes de tener
#   oportunidad de caer en la rama intermedia. Default: grab_window=3
#   (valor explicito del PDF), acceptance_n=10 (parametrizable, sin
#   valor recomendado en el PDF; elegido > grab_window a proposito).
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        k            => $args{k}            // 3,
        eq_factor    => $args{eq_factor}    // 0.10,
        grab_window  => $args{grab_window}  // 2,
        acceptance_n => $args{acceptance_n} // 5,
        atr_factor   => $args{atr_factor}   // 0.30,
        atr          => $args{atr},   # referencia DIRECTA al objeto ATR

        swings => [],   # todos los swings confirmados, en orden de confirmacion
        levels => [],   # TODOS los niveles (cualquier estado), en orden de creacion
        equals => [],   # pares EQH/EQL (puramente geometrico, no es un "nivel")
        events => [],   # eventos Sweep/Grab/Run ya resueltos

        _open_level_refs      => [],   # niveles en DETECTED o SWEPT (working set)
        _next_id               => 1,
        _last_evaluated_index  => -1,  # ultimo candidato de swing ya evaluado
    };

    die "Market::Indicators::Liquidity: acceptance_n debe ser > grab_window "
      . "(SWEEP nunca podria ocurrir si no)"
      if $self->{acceptance_n} <= $self->{grab_window};

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
}

# -----------------------------------------------------------------------------
# Accesores de solo lectura
# -----------------------------------------------------------------------------
sub get_values { return $_[0]->{levels}; }
sub get_swings { return $_[0]->{swings}; }
sub get_levels { return $_[0]->{levels}; }
sub get_equals { return $_[0]->{equals}; }
sub get_events { return $_[0]->{events}; }

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

    # ---- Anti-duplicado de niveles (working set, no el historico) ----
    # $level ya fue agregado a $self->{levels} dentro de _register_level
    # (eso NO se toca: cada swing siempre genera su registro historico).
    # Lo que se evita aqui es agregarlo al WORKING SET (_open_level_refs)
    # si ya existe un nivel DETECTED/SWEPT del mismo lado a menos de
    # 2*eq_factor*ATR de distancia -- eso es lo que produce eventos
    # Sweep/Grab duplicados casi identicos cuando varios swings muy
    # cercanos son barridos por el mismo movimiento de precio.
    my $is_duplicate = 0;
    {
        my $atr_vals = $self->{atr} ? $self->{atr}->get_values : undef;
        my $atr_v    = ($atr_vals && @$atr_vals) ? ($atr_vals->[-1] // 0) : 0;
        my $tol      = $atr_v * ($self->{eq_factor} * 2.0);
        if ($tol > 0) {
            for my $existing (@{ $self->{_open_level_refs} }) {
                if ($existing->{side} eq $level->{side}
                    && abs($existing->{price} - $level->{price}) <= $tol)
                {
                    $is_duplicate = 1;
                    last;
                }
            }
        }
    }
    push @{ $self->{_open_level_refs} }, $level unless $is_duplicate;

    $self->_check_equal_levels( $kind, $swing );
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
        origin_swing_id   => $swing->{id},
        state             => 'DETECTED',
        classification    => undef,
        swept_at_index    => undef,
        resolved_at_index => undef,

        # Etapa 6 (Fase 2): pesado de volumen multi-temporal + origen de TF.
        origin_tf => undef,
        volumes   => { '1m' => 0, '5m' => 0, '15m' => 0 },
    };

    $self->_attach_multi_tf_volume( $level, $swing, $market_data ) if $market_data;

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

    my $interval = $market_data->tf_interval_seconds($tf);
    return unless defined $interval;   # TF desconocida: deja volumes en 0

    my $ts_start = $swing->{ts};
    my $ts_end   = $ts_start + $interval;

    for my $sub_tf ( '1m', '5m', '15m' ) {
        $level->{volumes}{$sub_tf} =
            $market_data->sum_volume_for_tf_window( $sub_tf, $ts_start, $ts_end );
    }
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
# _check_equal_levels (privado)
# Compara el swing recien confirmado contra TODOS los swings previos del
# mismo tipo. Cada par dentro de tolerancia genera una entrada en
# get_equals() (puramente geometrica/informativa, no crea un nivel nuevo
# ni afecta la maquina de estados del nivel ya registrado por el swing).
# -----------------------------------------------------------------------------
sub _check_equal_levels {
    my ( $self, $kind, $new_swing ) = @_;
    return unless $self->{atr};

    my $atr_values = $self->{atr}->get_values;
    return unless $atr_values && @$atr_values;

    my $atr_at_new = $atr_values->[ $new_swing->{index} ];
    return unless defined $atr_at_new;

    my $tolerance = $atr_at_new * $self->{eq_factor};

    for my $prev ( @{ $self->{swings} } ) {
        next if $prev->{id} == $new_swing->{id};
        next unless $prev->{kind} eq $kind;

        my $diff = abs( $prev->{price} - $new_swing->{price} );
        next if $diff > $tolerance;

        push @{ $self->{equals} }, {
            kind => ( $kind eq 'H' ? 'EQH' : 'EQL' ),
            i1   => $prev->{index},
            i2   => $new_swing->{index},
            p1   => $prev->{price},
            p2   => $new_swing->{price},
        };
    }
}

# =============================================================================
# MAQUINA DE ESTADOS: Detected -> Swept -> (Acceptance|Reclaimed) -> Resolved
# =============================================================================

sub _update_state_machine {
    my ( $self, $market_data, $i ) = @_;
    my $candle = $market_data->get_candle($i);
    return unless $candle;

    my @still_open;
    for my $level ( @{ $self->{_open_level_refs} } ) {
        if ( $level->{state} eq 'DETECTED' ) {
            $self->_check_sweep( $level, $candle, $i );
        }
        if ( $level->{state} eq 'SWEPT' ) {
            $self->_check_resolution( $level, $candle, $i );
        }
        push @still_open, $level unless $level->{state} eq 'RESOLVED';
    }
    $self->{_open_level_refs} = \@still_open;
}

# -----------------------------------------------------------------------------
# _check_sweep (privado) -- Estado 1 (Detected) -> Estado 2 (Swept)
# BSL ('buy'): High > price.  SSL ('sell'): Low < price.
# -----------------------------------------------------------------------------
sub _check_sweep {
    my ( $self, $level, $candle, $i ) = @_;

    my $swept =
        ( $level->{side} eq 'buy' )
      ? ( $candle->{high} > $level->{price} )
      : ( $candle->{low}  < $level->{price} );
    return unless $swept;

    $level->{state}          = 'SWEPT';
    $level->{swept_at_index} = $i;
}

# -----------------------------------------------------------------------------
# _check_resolution (privado) -- Estado 2 (Swept) -> Estado 5 (Resolved)
# n_since incluye la propia vela del sweep (n_since=1 en esa misma vela).
# -----------------------------------------------------------------------------
sub _check_resolution {
    my ( $self, $level, $candle, $i ) = @_;

    my $n_since = $i - $level->{swept_at_index} + 1;

    my $closed_inside =
        ( $level->{side} eq 'buy' )
      ? ( $candle->{close} <= $level->{price} )
      : ( $candle->{close} >= $level->{price} );

    if ($closed_inside) {
        my $classification =
            ( $n_since <= $self->{grab_window} ) ? 'GRAB' : 'SWEEP';
        $self->_resolve( $level, $classification, $i );
        return;
    }

    if ( $n_since >= $self->{acceptance_n} ) {
        $self->_resolve( $level, 'RUN', $i );
        return;
    }

    # Sigue abierto (Swept), esperando resolucion en velas siguientes.
}

# -----------------------------------------------------------------------------
# _resolve (privado) -- Estado 5 (Resolved): clasificacion final inmutable
# + emite el evento correspondiente para get_events().
# -----------------------------------------------------------------------------
sub _resolve {
    my ( $self, $level, $classification, $i ) = @_;

    $level->{state}             = 'RESOLVED';
    $level->{classification}    = $classification;
    $level->{resolved_at_index} = $i;

    my $dir = ( $level->{side} eq 'buy' ) ? 'up' : 'down';
    push @{ $self->{events} }, {
        type  => $classification,   # 'SWEEP' | 'GRAB' | 'RUN'
        dir   => $dir,              # 'up' | 'down'
        index => $i,                # vela de RESOLUCION (no la del sweep)
        price => $level->{price},
        label => $self->side_label( $level->{side} ) . ' ' . $classification,
    };
}

1;