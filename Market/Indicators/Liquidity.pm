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
        k              => $args{k}              // 3,
        eq_factor      => $args{eq_factor}      // 0.10,
        eq_lookback    => $args{eq_lookback}    // 50,
        max_open_levels => $args{max_open_levels} // 150,
        track_volume    => defined $args{track_volume} ? $args{track_volume} : 1,
        grab_window  => $args{grab_window}  // 2,
        acceptance_n => $args{acceptance_n} // 5,
        # Ventana de CONTINUACION: tras un reclamo (cierre de vuelta dentro que
        # seria GRAB/SWEEP) se esperan estas velas; si el precio vuelve a romper
        # y continua en la direccion del barrido, se reclasifica como RUN
        # (corrige "grabs que en realidad eran LQ RUN"). 0 = resolver de
        # inmediato (comportamiento anterior).
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

        # Agregados del working set para el FAST-SKIP de la maquina de estados
        # (ver _update_state_machine). Permiten saltar en O(1) las velas en las
        # que ningun nivel puede transicionar, sin recorrer los ~150 niveles.
        _ws_dirty    => 1,      # los agregados necesitan recomputo
        _ws_min_buy  => 9e18,   # menor precio entre DETECTED buy  (+inf si no hay)
        _ws_max_sell => -9e18,  # mayor precio entre DETECTED sell (-inf si no hay)
        _ws_active   => 0,      # nº de niveles SWEPT/RECLAIMED pendientes
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
    $self->{_ws_dirty}    = 1;
    $self->{_ws_min_buy}  = 9e18;
    $self->{_ws_max_sell} = -9e18;
    $self->{_ws_active}   = 0;
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
# Empareja el swing recien confirmado con el swing previo MAS RECIENTE del
# mismo tipo que este dentro de tolerancia, y crea UN solo par EQH/EQL.
#
# Antes se comparaba contra TODOS los previos y se creaba un par por cada uno
# -> N lineas/etiquetas solapadas sobre la misma zona (ruido, spec 12). Al
# encadenar solo con el vecino inmediato, varios maximos/minimos "iguales"
# consecutivos forman un unico cluster horizontal limpio en lugar de una
# maraña de segmentos cruzados. (Puramente geometrico: no crea un nivel nuevo
# ni afecta la maquina de estados del nivel ya registrado por el swing.)
# -----------------------------------------------------------------------------
sub _check_equal_levels {
    my ( $self, $kind, $new_swing ) = @_;
    return unless $self->{atr};

    my $atr_values = $self->{atr}->get_values;
    return unless $atr_values && @$atr_values;

    my $atr_at_new = $atr_values->[ $new_swing->{index} ];
    return unless defined $atr_at_new;

    my $tolerance = $atr_at_new * $self->{eq_factor};

    # Recorrer de mas reciente a mas antiguo y detenerse en el primer swing
    # del mismo tipo dentro de tolerancia. Se limita la busqueda a los ultimos
    # eq_lookback swings: los EQH/EQL son un fenomeno LOCAL (maximos/minimos
    # cercanos en el tiempo) y ademas evita el coste O(n^2) de escanear todo el
    # historico cuando un swing no tiene par (lo que congelaba el rebuild del
    # replay en datasets grandes).
    my $swings   = $self->{swings};
    my $lookback = $self->{eq_lookback};
    my $stop     = $#$swings - $lookback;
    $stop = 0 if $stop < 0;
    for (my $j = $#$swings; $j >= $stop; $j--) {
        my $prev = $swings->[$j];
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
        last;   # solo el vecino igual mas cercano -> una sola zona
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
    #   * no hay niveles SWEPT/RECLAIMED pendientes (esos dependen del tiempo y
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
    my $cw = $self->{continuation_window};

    # Se reconstruye el working set y, en la misma pasada, los agregados del
    # fast-skip segun el estado RESULTANTE de cada nivel.
    my @still_open;
    my $min_buy  = 9e18;
    my $max_sell = -9e18;
    my $active   = 0;
    for my $level ( @{ $self->{_open_level_refs} } ) {
        my $buy = ( $level->{side} eq 'buy' );
        my $price = $level->{price};

        # Detected -> Swept
        if ( $level->{state} eq 'DETECTED' ) {
            if ( $buy ? ( $ch > $price ) : ( $cl < $price ) ) {
                $level->{state}          = 'SWEPT';
                $level->{swept_at_index} = $i;
            }
        }

        # Swept -> (Reclaimed, pendiente) / Run
        if ( $level->{state} eq 'SWEPT' ) {
            my $n_since = $i - $level->{swept_at_index} + 1;
            my $inside  = $buy ? ( $cc <= $price ) : ( $cc >= $price );
            if ($inside) {
                if ( $cw > 0 ) {
                    # cerro de vuelta dentro: candidato a GRAB (rapido) o SWEEP
                    # (lento). NO se resuelve aun: se espera continuation_window
                    # velas para ver si el precio vuelve a romper y CONTINUA (RUN).
                    $level->{state}         = 'RECLAIMED';
                    $level->{reclaim_at}    = $i;
                    $level->{pending_class} = ( $n_since <= $gw ) ? 'GRAB' : 'SWEEP';
                } else {
                    $self->_resolve( $level,
                        ( $n_since <= $gw ? 'GRAB' : 'SWEEP' ), $i );
                }
            } elsif ( $n_since >= $an ) {
                $self->_resolve( $level, 'RUN', $i );
            }
        }

        # Reclaimed -> Run (si vuelve a romper y continua) | Grab/Sweep (si se
        # mantiene dentro tras continuation_window velas).
        elsif ( $level->{state} eq 'RECLAIMED' ) {
            my $outside_again = $buy ? ( $cc > $price ) : ( $cc < $price );
            if ($outside_again) {
                $self->_resolve( $level, 'RUN', $i );
            } elsif ( ( $i - $level->{reclaim_at} ) >= $cw ) {
                $self->_resolve( $level, $level->{pending_class}, $i );
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
            $active++;   # SWEPT o RECLAIMED: siempre revisar la proxima vela
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