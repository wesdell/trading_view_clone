package Market::Indicators::SMC_Structures;

use strict;
use warnings;

# FASE-2.2: pesos de confluencia con eventos de Liquidity. El refuerzo es
# ADITIVO sobre el peso base (1.0) y configurable; refleja el "incremento
# drastico" de la spec 5 sin CREAR estructura (solo pondera la ya detectada).
use constant {
    LIQ_WEIGHT_BASE  => 1.0,   # peso base de todo BOS/CHoCH
    LIQ_SWEEP_BOOST  => 1.0,   # Sweep contrario -> refuerza CHoCH
    LIQ_RUN_BOOST    => 1.0,   # Run a favor    -> refuerza BOS
    LIQ_REL_LOOKBACK => 20,    # ventana (velas) de vigencia de un evento de Liquidity
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        zigzag             => $args{zigzag},
        atr                => $args{atr},
        # Referencia de SOLO LECTURA al indicador Liquidity ya calculado (FASE
        # 2.1). SMC NO recalcula Liquidity: consume get_events() via un cursor.
        # En rebuild_all el orden de registro (liquidity antes que smc) garantiza
        # que los eventos de la vela i ya existen cuando SMC procesa la vela i.
        liquidity          => $args{liquidity},
        max_age            => $args{max_age}           // 50,
        min_fvg_atr_mult   => $args{min_fvg_atr_mult}  // 0.20,
        ob_proximity_mult  => $args{ob_proximity_mult}  // 6.0,

        _c            => [],
        _fvgs         => [],
        _active_fvgs  => [],
        _events       => [],
        _order_blocks => [],
        _active_obs   => [],

        # FASE-2.2: integracion Liquidity -> SMC (relaciones, paso 8 por vela).
        _liq_seen         => 0,    # cursor: nº de eventos de Liquidity ya consumidos
        _liq_recent       => [],   # eventos de Liquidity vigentes (ventana lookback)
        _reversal_alerts  => [],   # alertas de reversion generadas por Grabs

        # Las etiquetas HH/HL/LH/LL se derivan 1:1 de los segmentos del ZigZag
        # INTERNO (verde/rojo) de Indicators::ZigZag -- esto NO se toca: el
        # zigzag interno/externo (lineas verde-rojo y azul) sigue funcionando
        # exactamente igual que antes de este cambio.
        _struct => _mk_struct_state(),

        # BOS/CHoCH: motor INDEPENDIENTE del zigzag interno/externo de arriba,
        # portado directo del indicador de referencia (LuxAlgo "Smart Money
        # Concepts"): pivote simetrico leg(size) + crossover/crossunder del
        # cierre contra el ultimo pivote no cruzado. 'internal' (size=5) replica
        # su "Internal Structure"; 'swing' (size=50) replica su "Swing
        # Structure" (lo que aqui llamamos BOS/CHoCH externo). No depende de
        # HH/HL/LH/LL ni de los pivotes del zigzag interno/externo.
        _bos => {
            internal => _mk_leg_state( $args{bos_internal_size} // 5 ),
            external => _mk_leg_state( $args{bos_swing_size}    // 50 ),
        },
    };
    bless $self, $class;
    return $self;
}

# _mk_struct_state: estado de los pivotes HH/HL/LH/LL espejados del zigzag interno.
sub _mk_struct_state {
    return {
        swings    => [],
        zz_seen_n => 0,   # cuantos segmentos del zigzag interno ya se copiaron
    };
}

# _mk_leg_state: estado del motor BOS/CHoCH estilo LuxAlgo para un scope.
# leg_dir: 0=BEARISH_LEG, 1=BULLISH_LEG (arranca en 0, igual que "var leg=0" de
# Pine). pivot_high/pivot_low: {level,last,crossed,index} -- level es el precio
# del pivote vigente (aun no roto); crossed evita relanzar el mismo evento.
sub _mk_leg_state {
    my ($size) = @_;
    return {
        size     => $size,
        leg_dir  => 0,
        pivot_hi => { level => undef, last => undef, crossed => 0, index => undef },
        pivot_lo => { level => undef, last => undef, crossed => 0, index => undef },
        trend    => undef,
    };
}

sub get_values          { return []; }
sub get_fvgs            { return $_[0]->{_fvgs}; }
sub get_events          { return $_[0]->{_events}; }
sub get_struct_swings   { return $_[0]->{_struct}{swings}; }
sub get_order_blocks    { return $_[0]->{_order_blocks}; }
sub get_reversal_alerts { return $_[0]->{_reversal_alerts}; }   # FASE-2.2 (Grabs)

sub processed_last    { return $#{ $_[0]->{_c} }; }

sub reset {
    my ($self) = @_;
    $self->{_c}            = [];
    $self->{_fvgs}         = [];
    $self->{_active_fvgs}  = [];
    $self->{_events}       = [];
    $self->{_order_blocks} = [];
    $self->{_active_obs}   = [];
    $self->{_liq_seen}        = 0;    # FASE-2.2: cursor y buffers de relaciones
    $self->{_liq_recent}      = [];
    $self->{_reversal_alerts} = [];
    $self->{_struct}       = _mk_struct_state();
    $self->{_bos} = {
        internal => _mk_leg_state( $self->{_bos}{internal}{size} ),
        external => _mk_leg_state( $self->{_bos}{external}{size} ),
    };
}

sub update_at_index {
    my ($self, $md, $idx) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_process($c);
}

sub update_last {
    my ($self, $md) = @_;
    my $c = $md->last_candle;
    return unless defined $c;
    $self->_process($c);
}

sub _process {
    my ($self, $c) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };
    $self->_sync_from_zigzag;          # (5) estructura HH/HL/LH/LL
    $self->_detect_fvg($i);            # (7) FVG (no interactua con BOS/CHoCH)
    $self->_update_fvgs($i);
    $self->_update_obs($i);
    $self->_detect_bos_choch($i);      # (6) BOS/CHoCH
    $self->_apply_liquidity_relations($i);   # (8) relaciones Liquidity -> SMC
}

# -----------------------------------------------------------------------------
# _sync_from_zigzag: _struct_swings (HH/HL/LH/LL) espeja 1:1 los segmentos del
# ZigZag INTERNO (verde/rojo) de Indicators::ZigZag (get_segments('internal')).
# SOLO alimenta las etiquetas HH/HL/LH/LL -- el BOS/CHoCH ya NO depende de esto
# (ver _detect_bos_choch, motor propio estilo LuxAlgo). No toca el zigzag
# interno/externo en si (Indicators::ZigZag), que sigue intacto.
# -----------------------------------------------------------------------------
sub _sync_from_zigzag {
    my ($self) = @_;
    my $zz = $self->{zigzag};
    return unless $zz;

    my $segs = $zz->get_segments('internal');
    return unless $segs && @$segs;

    my $st = $self->{_struct};

    # Indicators::ZigZag::update_at_index no esta parametrizado por el indice
    # de este tick: usa $md->last_index, que en un rebuild_all SIN frontera de
    # replay devuelve el ULTIMO indice de TODO el dataset ya cargado. Por eso
    # sus segmentos pueden materializarse de golpe muy por delante de este
    # indicador (que si avanza vela a vela via _c). Para no adelantarnos,
    # solo se copian/extienden segmentos cuyo ts NO supere la ultima vela ya
    # vista en _c -- el resto se sincroniza en ticks posteriores conforme _c
    # los va alcanzando.
    my $now_ts = $self->{_c}[-1]{ts};
    my $list   = $st->{swings};
    my $n      = scalar @$segs;

    while ($st->{zz_seen_n} < $n) {
        my $seg = $segs->[ $st->{zz_seen_n} ];
        last if $seg->{ts} > $now_ts;
        my $idx = $self->_ts_to_index($seg->{ts});
        push @$list, _mk_pivot({ kind  => $seg->{kind}, index => $idx,
                                  price => $seg->{price}, ts => $seg->{ts} });
        $self->_relabel_last;
        $st->{zz_seen_n}++;
    }
    return if $st->{zz_seen_n} < $n;   # aun quedan segmentos "futuros" por alcanzar

    my $seg = $segs->[-1];
    return if $seg->{ts} > $now_ts;
    my $last = $list->[-1];
    return unless $last;
    return if $seg->{price} == $last->{price} && $seg->{ts} == $last->{ts};

    $last->{price} = $seg->{price};
    $last->{ts}    = $seg->{ts};
    $last->{index} = $self->_ts_to_index($seg->{ts});
    $self->_relabel_last;
}

# -----------------------------------------------------------------------------
# _ts_to_index: indice en _c (aligned 1:1 con la TF activa que usa el ZigZag
# interno, ver market.pl: ambos se recorren en el mismo orden en rebuild_all)
# cuyo ts es el mas cercano (sin pasarse) a $ts_target. Busqueda binaria, igual
# criterio que Overlays::ZigZag::_ts_to_active_idx.
# -----------------------------------------------------------------------------
sub _ts_to_index {
    my ($self, $ts_target) = @_;
    my $c = $self->{_c};
    my ($lo, $hi) = (0, $#$c);
    return 0 if $hi < 0;
    return 0 if $c->[0]{ts} > $ts_target;
    return $hi if $c->[$hi]{ts} <= $ts_target;

    my $found = 0;
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($c->[$mid]{ts} <= $ts_target) { $found = $mid; $lo = $mid + 1; }
        else                              { $hi = $mid - 1; }
    }
    return $found;
}

# _mk_pivot: crea el pivote; la etiqueta final la fija _relabel_last.
sub _mk_pivot {
    my ($sw) = @_;
    return {
        index => $sw->{index}, price => $sw->{price},
        kind  => $sw->{kind},
        label => ($sw->{kind} eq 'H' ? 'HH' : 'LL'),
        ts    => $sw->{ts},
    };
}

# _relabel_last: HH/LH (o HL/LL) comparando el ultimo pivote contra el pivote
# previo del MISMO tipo en la lista ya limpia. Solo alimenta las etiquetas
# mostradas sobre el zigzag interno (el BOS/CHoCH ya no lee estos niveles).
sub _relabel_last {
    my ($self) = @_;
    my $list = $self->{_struct}{swings};
    return unless @$list;
    my $cur = $list->[-1];

    my $prev;
    for (my $j = $#$list - 1; $j >= 0; $j--) {
        if ($list->[$j]{kind} eq $cur->{kind}) { $prev = $list->[$j]; last; }
    }

    if ($cur->{kind} eq 'H') {
        $cur->{label} = (!$prev || $cur->{price} > $prev->{price}) ? 'HH' : 'LH';
    } else {
        $cur->{label} = (!$prev || $cur->{price} < $prev->{price}) ? 'LL' : 'HL';
    }
}

# -----------------------------------------------------------------------------
# _detect_fvg: patron 3 velas con filtro por tamano ATR.
# 'significant' => el overlay decide si renderizar o no.
# -----------------------------------------------------------------------------
sub _detect_fvg {
    my ($self, $i) = @_;
    return if $i < 2;
    my $c = $self->{_c};
    my $a = $c->[$i-2];
    my $z = $c->[$i];

    my $atr_val = ($self->{atr} ? ($self->{atr}->get_values->[$i] // 0) : 0);
    my $min_sz  = $atr_val * $self->{min_fvg_atr_mult};

    my ($dir, $bottom, $top);
    if    ($z->{low}  > $a->{high}) { ($dir,$bottom,$top) = ('bull', $a->{high}, $z->{low});  }
    elsif ($z->{high} < $a->{low})  { ($dir,$bottom,$top) = ('bear', $z->{high}, $a->{low}); }
    else { return; }

    my $fvg = {
        dir         => $dir,
        idx_start   => $i-2,
        idx_create  => $i,
        ts_start    => $c->[$i-2]{ts},
        ts_create   => $c->[$i]{ts},
        created     => $i,
        bottom      => $bottom,
        top         => $top,
        state       => 'active',
        mitig_at    => undef,
        # Frontera de la zona AUN NO consumida (consumo progresivo, spec 13.5):
        #  - bull: arranca en top y baja hacia bottom conforme el precio entra;
        #          zona restante = [bottom, consumed_to].
        #  - bear: arranca en bottom y sube hacia top; restante = [consumed_to, top].
        consumed_to => ($dir eq 'bull' ? $top : $bottom),
        significant => (($top - $bottom) >= $min_sz),
        # FASE-2.2: se completa en _apply_liquidity_relations si coincide con un
        # Sweep/Grab. NO se duplica el FVG: es el MISMO objeto con clasificacion.
        reaction_zone => 0,
        liq_event_id  => undef,
        liq_type      => undef,
    };
    push @{ $self->{_fvgs} }, $fvg;
    push @{ $self->{_active_fvgs} }, $fvg if $fvg->{significant};
}

sub _update_fvgs {
    my ($self, $i) = @_;
    my $cur = $self->{_c}[$i];
    my @keep;
    for my $f (@{ $self->{_active_fvgs} }) {
        # Aun no evaluable (misma vela de creacion): CONSERVAR en el working
        # set. Antes se hacia 'next' aqui, lo que descartaba el FVG en su vela
        # de creacion y hacia que NUNCA se marcara mitigado/expirado -> los FVG
        # consumidos no desaparecian (spec 17). Ahora se mantiene y se evalua
        # desde la vela siguiente.
        if ($i <= $f->{created}) { push @keep, $f; next; }

        # Consumo progresivo: avanzar la frontera consumed_to segun cuanto
        # penetro el precio en la zona; mitigar (desaparecer) al cubrirla toda.
        if ($f->{dir} eq 'bull') {
            $f->{consumed_to} = $cur->{low} if $cur->{low} < $f->{consumed_to};
            if ($cur->{low} <= $f->{bottom}) { $f->{state}='mitigated'; $f->{mitig_at}=$i; next; }
        } else {
            $f->{consumed_to} = $cur->{high} if $cur->{high} > $f->{consumed_to};
            if ($cur->{high} >= $f->{top}) { $f->{state}='mitigated'; $f->{mitig_at}=$i; next; }
        }
        if (($i - $f->{created}) > $self->{max_age})             { $f->{state}='expired';   next; }
        push @keep, $f;
    }
    $self->{_active_fvgs} = \@keep;
}

# -----------------------------------------------------------------------------
# _detect_bos_choch: motor BOS/CHoCH independiente del ZigZag interno/externo
# de arriba, portado directo de LuxAlgo "Smart Money Concepts" (ver
# leg()/getCurrentStructure()/displayStructure() en el Pine original).
# Dos scopes con estado propio: 'internal' (size=5, su "Internal Structure") y
# 'external' (size=50, su "Swing Structure" -- lo que aqui llamamos externo).
# -----------------------------------------------------------------------------
sub _detect_bos_choch {
    my ($self, $i) = @_;
    $self->_update_leg_scope($i, 'internal');
    $self->_update_leg_scope($i, 'external');
}

# -----------------------------------------------------------------------------
# _update_leg_scope: replica leg(size) + getCurrentStructure() +
# displayStructure() de LuxAlgo para un scope.
#
# leg(size): la vela 'size' velas atras es un pivote HIGH confirmado si su high
# supera al high mas alto de las 'size' velas siguientes (sin contarla a ella
# misma); simetricamente para el pivote LOW. Solo se registra pivote nuevo
# cuando la direccion (leg_dir) CAMBIA respecto al bar anterior -- por eso el
# pivote queda "confirmado" recien 'size' velas despues de formarse (igual
# demora que en TradingView, no hay fuga de futuro).
#
# displayStructure(): en CADA vela se prueba cruce del close contra el ultimo
# pivote alto/bajo aun no cruzado ('crossed'=0); el tipo es CHoCH si contradice
# la tendencia vigente del scope, BOS si la confirma. 'crossed' evita relanzar
# el mismo evento hasta que un pivote nuevo lo reemplace.
# -----------------------------------------------------------------------------
sub _update_leg_scope {
    my ($self, $i, $scope) = @_;
    my $st   = $self->{_bos}{$scope};
    my $size = $st->{size};
    my $c    = $self->{_c};

    if ($i >= $size) {
        my ($hi_max, $lo_min) = ($c->[$i]{high}, $c->[$i]{low});
        for (my $j = $i - $size + 1; $j < $i; $j++) {
            $hi_max = $c->[$j]{high} if $c->[$j]{high} > $hi_max;
            $lo_min = $c->[$j]{low}  if $c->[$j]{low}  < $lo_min;
        }
        my $cand          = $c->[$i - $size];
        my $new_leg_high  = ($cand->{high} > $hi_max);
        my $new_leg_low   = ($cand->{low}  < $lo_min);

        my $prev_dir = $st->{leg_dir};
        my $dir      = $prev_dir;
        $dir = 0 if $new_leg_high;   # BEARISH_LEG (pivote alto confirmado)
        $dir = 1 if $new_leg_low;    # BULLISH_LEG (pivote bajo confirmado)
        $st->{leg_dir} = $dir;

        if ($dir != $prev_dir) {
            my $p = ($dir == 1) ? $st->{pivot_lo} : $st->{pivot_hi};
            $p->{last}    = $p->{level};
            $p->{level}   = ($dir == 1) ? $cand->{low} : $cand->{high};
            $p->{crossed} = 0;
            $p->{index}   = $i - $size;
        }
    }

    return if $i < 1;
    my $prev_close = $c->[$i-1]{close};
    my $cur_close  = $c->[$i]{close};

    # Cruce alcista: close cruza por ENCIMA del ultimo pivote alto no cruzado.
    my $ph = $st->{pivot_hi};
    if (defined $ph->{level} && !$ph->{crossed}
        && $prev_close <= $ph->{level} && $cur_close > $ph->{level})
    {
        my $type = (defined $st->{trend} && $st->{trend} eq 'bear') ? 'CHoCH' : 'BOS';
        $ph->{crossed} = 1;
        $st->{trend}   = 'bull';
        $self->_emit($type, 'up', $i, $ph->{level}, $ph->{index}, $scope);
    }

    # Cruce bajista: close cruza por DEBAJO del ultimo pivote bajo no cruzado.
    my $pl = $st->{pivot_lo};
    if (defined $pl->{level} && !$pl->{crossed}
        && $prev_close >= $pl->{level} && $cur_close < $pl->{level})
    {
        my $type = (defined $st->{trend} && $st->{trend} eq 'bull') ? 'CHoCH' : 'BOS';
        $pl->{crossed} = 1;
        $st->{trend}   = 'bear';
        $self->_emit($type, 'down', $i, $pl->{level}, $pl->{index}, $scope);
    }
}

# FIX (entrega 2, revision ingeniero): antes SOLO se generaba Order Block
# para eventos de scope INTERNO ("return unless $scope eq 'internal'"), asi
# que ningun BOS/CHoCH externo producia OB propio -- por eso no se veian ni
# se calculaban los OB externos. Ahora ambos scopes buscan su OB; se propaga
# $scope al OB para que el overlay lo diferencie visualmente con el mismo
# criterio ya usado en BOS/CHoCH (interno=punteado/chip chico,
# externo=solido/chip normal).
sub _emit {
    my ($self, $type, $dir, $i, $price, $origin, $scope) = @_;
    $scope //= 'internal';

    push @{ $self->{_events} }, {
        type   => $type,
        dir    => $dir,
        index  => $i,
        origin => $origin,
        ts     => $self->{_c}[$i]{ts},
        price  => $price,
        label  => $type,
        scope  => $scope,
        # FASE-2.2: peso de probabilidad (base 1.0); se refuerza en
        # _apply_liquidity_relations si hay confluencia con Sweep/Run. La
        # estructura NUNCA se crea por Liquidity, solo se pondera.
        weight        => LIQ_WEIGHT_BASE,
        liq_confluence => undef,
    };

    # Order Block: ultimo cuerpo contra-tendencia entre origin e i-1
    my $ob_dir   = ($dir eq 'up') ? 'bull' : 'bear';
    my $ob_start = defined($origin) ? $origin : (_max(0, $i - 30));
    my $ob = $self->_find_order_block($ob_dir, $ob_start, $i - 1);
    if ($ob) {
        $ob->{scope} = $scope;
        push @{ $self->{_order_blocks} }, $ob;
        push @{ $self->{_active_obs} },   $ob;
    }
}

sub _find_order_block {
    my ($self, $dir, $start, $end) = @_;
    my $c = $self->{_c};
    for (my $j = $end; $j >= $start; $j--) {
        my $candle = $c->[$j] or next;
        if ($dir eq 'bull' && $candle->{close} < $candle->{open}) {
            return { dir=>'bull', idx=>$j, ts=>$candle->{ts},
                     zone_low=>$candle->{low}, zone_high=>$candle->{open},
                     open=>$candle->{open}, high=>$candle->{high},
                     low=>$candle->{low},   close=>$candle->{close},
                     state=>'active', broken_at=>undef };
        }
        if ($dir eq 'bear' && $candle->{close} > $candle->{open}) {
            return { dir=>'bear', idx=>$j, ts=>$candle->{ts},
                     zone_low=>$candle->{open}, zone_high=>$candle->{high},
                     open=>$candle->{open}, high=>$candle->{high},
                     low=>$candle->{low},   close=>$candle->{close},
                     state=>'active', broken_at=>undef };
        }
    }
    return undef;
}

sub _update_obs {
    my ($self, $i) = @_;
    my $cur = $self->{_c}[$i];
    my @keep;
    for my $ob (@{ $self->{_active_obs} }) {
        next if $i <= $ob->{idx};
        if ($ob->{dir} eq 'bull' && $cur->{close} < $ob->{zone_low})  { $ob->{state}='broken'; $ob->{broken_at}=$i; next; }
        if ($ob->{dir} eq 'bear' && $cur->{close} > $ob->{zone_high}) { $ob->{state}='broken'; $ob->{broken_at}=$i; next; }
        push @keep, $ob;
    }
    $self->{_active_obs} = \@keep;
}

# -----------------------------------------------------------------------------
# _apply_liquidity_relations (FASE-2.2, paso 8) -- relaciones Liquidity -> SMC.
# CONSUME (no recalcula) los eventos ya resueltos por Indicators::Liquidity via
# un cursor monotono. Reglas de la spec 5:
#   * Sweep  -> refuerza el peso de un CHoCH en direccion CONTRARIA al barrido
#               (un Sweep de BSL, dir 'up', apoya un CHoCH 'down'). No crea CHoCH.
#   * Run    -> refuerza el peso/continuidad de un BOS en la MISMA direccion.
#               No crea BOS (solo pondera el ya detectado por pivote valido).
#   * Grab   -> genera una ALERTA de reversion (dir contraria + tf del evento).
#               No es entrada; conserva id/direccion/timeframe del evento.
#   * FVG en la vela del Sweep/Grab (o inmediatamente posterior) -> "Zona de Alta
#               Reaccion" con el id del evento, SIN duplicar el FVG.
# Sin futuro: solo se consumen eventos con confirmed_ts <= ts de la vela actual;
# el orden de registro (liquidity antes que smc) los deja listos para la vela i.
# -----------------------------------------------------------------------------
sub _apply_liquidity_relations {
    my ($self, $i) = @_;
    my $liq = $self->{liquidity} or return;   # SMC funciona igual sin Liquidity
    my $c   = $self->{_c};
    my $ts  = $c->[$i]{ts};

    # (a) avanzar el cursor: consumir eventos de Liquidity ya confirmados.
    my $levents = $liq->get_events;
    while ( $self->{_liq_seen} < scalar(@$levents) ) {
        my $e = $levents->[ $self->{_liq_seen} ];
        last if $e->{confirmed_ts} > $ts;     # aun no confirmado a esta altura (sin futuro)
        $self->{_liq_seen}++;
        push @{ $self->{_liq_recent} }, $e;

        # (c) Grab -> alerta de reversion (NO entrada). Conserva dir y tf.
        if ( $e->{type} eq 'GRAB' ) {
            push @{ $self->{_reversal_alerts} }, {
                dir          => ( $e->{dir} eq 'up' ? 'down' : 'up' ),
                tf           => $e->{origin_tf},
                ts           => $e->{confirmed_ts},
                index        => $i,
                price        => $e->{price},
                liq_event_id => $e->{level_id},
                source       => 'GRAB',
            };
        }
    }

    # podar el buffer de eventos vigentes a la ventana lookback
    my $lo_i  = $i - LIQ_REL_LOOKBACK; $lo_i = 0 if $lo_i < 0;
    my $lo_ts = $c->[$lo_i]{ts};
    @{ $self->{_liq_recent} } = grep { $_->{confirmed_ts} >= $lo_ts } @{ $self->{_liq_recent} };

    # (b) reforzar el peso de los BOS/CHoCH emitidos EN ESTA vela (index == i).
    for ( my $k = $#{ $self->{_events} }; $k >= 0; $k-- ) {
        my $ev = $self->{_events}[$k];
        last if $ev->{index} != $i;             # los de esta vela estan al final
        next if defined $ev->{liq_confluence};
        if ( $ev->{type} eq 'CHoCH' ) {
            my $want = ( $ev->{dir} eq 'up' ) ? 'down' : 'up';   # Sweep CONTRARIO
            my $s = $self->_recent_liq( 'SWEEP', $want );
            if ($s) {
                $ev->{weight} += LIQ_SWEEP_BOOST;
                $ev->{liq_confluence} = { type=>'SWEEP', event_id=>$s->{level_id}, dir=>$s->{dir} };
            }
        }
        elsif ( $ev->{type} eq 'BOS' ) {
            my $r = $self->_recent_liq( 'RUN', $ev->{dir} );      # Run a FAVOR
            if ($r) {
                $ev->{weight} += LIQ_RUN_BOOST;
                $ev->{liq_confluence} = { type=>'RUN', event_id=>$r->{level_id}, dir=>$r->{dir} };
            }
        }
    }

    # (d) FVG creado en esta vela: "Zona de Alta Reaccion" si un Sweep/Grab rompio
    #     en una de sus velas (i-2..i) o inmediatamente antes (i-3). Sin duplicar.
    my $f = $self->{_fvgs}[-1];
    if ( $f && $f->{idx_create} == $i && !$f->{reaction_zone} ) {
        my %span = map { $c->[$_]{ts} => 1 } grep { $_ >= 0 } ( $i - 3 .. $i );
        for my $e ( reverse @{ $self->{_liq_recent} } ) {
            next unless $e->{type} eq 'SWEEP' || $e->{type} eq 'GRAB';
            if ( $span{ $e->{break_ts} } ) {
                $f->{reaction_zone} = 1;
                $f->{liq_event_id}  = $e->{level_id};
                $f->{liq_type}      = $e->{type};
                last;
            }
        }
    }
}

# _recent_liq: evento de Liquidity vigente mas reciente del tipo y direccion dados.
sub _recent_liq {
    my ($self, $type, $dir) = @_;
    for my $e ( reverse @{ $self->{_liq_recent} } ) {
        return $e if $e->{type} eq $type && $e->{dir} eq $dir;
    }
    return undef;
}

sub _max { $_[0] > $_[1] ? $_[0] : $_[1] }

1;