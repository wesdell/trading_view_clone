package Market::Indicators::SMC_Structures;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        liquidity          => $args{liquidity},
        atr                => $args{atr},
        max_age            => $args{max_age}           // 50,
        min_fvg_atr_mult   => $args{min_fvg_atr_mult}  // 0.20,
        ob_proximity_mult  => $args{ob_proximity_mult}  // 6.0,

        # --- Filtros de la linea estructural (ZigZag de ESTRUCTURA MAYOR) ---
        # Una nueva pierna (pivote de lado opuesto) solo se acepta si el
        # movimiento contra el pivote anterior supera struct_atr_mult*ATR y
        # ademas hay al menos struct_min_bars velas de separacion. Los pivotes
        # del mismo lado se fusionan conservando el extremo mas relevante, y la
        # consistencia direccional descarta pivotes solapados. Con un umbral
        # alto (~2.5) la linea representa la estructura mayor del mercado y los
        # retrocesos internos NO la cortan (spec 1/7). Subir el factor => linea
        # aun mas limpia; bajarlo => mas detalle. structure_atr_factor del PDF.
        struct_atr_mult    => $args{struct_atr_mult}   // 2.5,
        struct_min_bars    => $args{struct_min_bars}   // 3,
        # Umbral (en ATR) de la REVERSION que confirma una nueva pierna del
        # zigzag EXTERNO (get_main_struct / linea azul de estructura mayor). Una
        # reversion contra el ultimo pivote menor a main_atr_mult*ATR se ignora
        # (interna). Mas alto = linea externa mas gruesa/mayor; mas bajo = mas
        # detalle. Sustituye al antiguo main_retrace (colapso greedy).
        main_atr_mult      => $args{main_atr_mult}     // 3.5,
        # Tolerancia (en ATR) para detectar DOBLE-TECHO / DOBLE-PISO en el
        # zigzag externo: si un nuevo extremo esta a <= main_dtop_atr*ATR del
        # pivote previo del mismo lado, es un RETEST del mismo nivel y NO se
        # cuenta como pierna nueva -> la estructura toma el lower-high /
        # higher-low posterior (estructura de mercado, no pico geometrico).
        main_dtop_atr      => $args{main_dtop_atr}     // 1.0,

        # --- ZigZag EXTERNO estilo TradingView (linea azul de estructura mayor)
        # Portado de los indicadores de TradingView "ZZMTF" (© LonesomeTheBlue) y
        # "ZigZag Volume Profile" (© ChartPrime): el pivote es CAUSAL -- la vela
        # actual es swing-high si su high es el MAYOR de las ultimas main_prd
        # velas (ta.highest / ta.lowest, highestbars==0), y swing-low si su low es
        # el MENOR. La direccion (dir) cambia al aparecer un nuevo extremo del
        # lado opuesto; cada cambio de direccion fija un pivote y la pierna en
        # curso se extiende hasta su extremo. Sustituye al zigzag por umbral-ATR
        # (que saltaba pivotes cuando el ATR daba un pico). main_prd = "period" de
        # ZZMTF / "swingLength" del Volume Profile: mas alto => estructura mas
        # mayor (menos pivotes). Sin fuga de futuro (solo mira hacia atras).
        main_prd           => $args{main_prd}         // 30,

        # Confirmacion por VOLUMEN de los pivotes estructurales (spec docente:
        # "considerar volatilidad Y volumen"). Un pivote nuevo se acepta si el
        # volumen de su vela supera volume_ma(volume_ma_period) * volume_factor.
        # TOLERANTE: si el dataset no tiene volumen (promedio 0) no filtra. Solo
        # afecta las etiquetas HH/HL/LH/LL (no sweep/grab/EQ). use_volume=0 lo
        # desactiva.
        use_volume         => defined $args{use_volume} ? $args{use_volume} : 1,
        volume_ma_period   => $args{volume_ma_period}  // 20,
        volume_factor      => $args{volume_factor}     // 1.0,

        _c            => [],
        _fvgs         => [],
        _active_fvgs  => [],
        _events       => [],
        _order_blocks => [],
        _active_obs   => [],

        _struct_swings  => [],
        _seen_sh_idx    => -1,
        _seen_sl_idx    => -1,

        # Estado del ZigZag externo estilo TradingView (ver main_prd).
        _zz_dir     => 0,    # 0 = sin definir, 1 = alcista, -1 = bajista
        _zz_pivots  => [],   # pivotes alternados {kind,index,price,ts}
        _last_hh => undef, _last_hl => undef,
        _last_lh => undef, _last_ll => undef,

        _bias    => undef,
        _bh_idx  => -1,
        _bl_idx  => -1,
        _new_sl_since_last_up   => 0,
        _new_sh_since_last_down => 0,
    };
    bless $self, $class;
    return $self;
}

sub get_values        { return []; }
sub get_fvgs          { return $_[0]->{_fvgs}; }
sub get_events        { return $_[0]->{_events}; }
sub get_struct_swings { return $_[0]->{_struct_swings}; }
sub get_order_blocks  { return $_[0]->{_order_blocks}; }

# -----------------------------------------------------------------------------
# get_main_struct: version COMPACTADA de _struct_swings para dibujar la LINEA
# principal. Colapsa los pivotes internos de un tramo fuerte (spec 5/7):
# mientras la tendencia sigue extendiendose (highs cada vez mas altos con lows
# cada vez mas altos -- o lows mas bajos con highs mas bajos), los pivotes
# intermedios se absorben y la linea une DIRECTAMENTE el origen con el extremo
# principal (p.ej. LL -> HH directo, sin el HH/HL interno).
#
# Es un derivado de solo lectura: NO altera _struct_swings (que conserva el
# detalle para BOS/CHoCH) ni las etiquetas HH/HL/LH/LL (que se siguen mostrando
# sobre TODOS los pivotes crudos). Sin fuga de futuro: solo usa pivotes ya
# confirmados. O(n) por llamada (n = pivotes estructurales), se calcula al
# renderizar.
# -----------------------------------------------------------------------------
sub get_main_struct {
    my ($self) = @_;
    # La linea externa (azul) es ahora el ZigZag causal estilo TradingView que
    # se mantiene incrementalmente en _update_main_zigzag (portado de ZZMTF /
    # ZigZag Volume Profile). Devolver directamente sus pivotes ya alternados.
    return $self->{_zz_pivots};
}
sub processed_last    { return $#{ $_[0]->{_c} }; }

sub reset {
    my ($self) = @_;
    $self->{_c}            = [];
    $self->{_fvgs}         = [];
    $self->{_active_fvgs}  = [];
    $self->{_events}       = [];
    $self->{_order_blocks} = [];
    $self->{_active_obs}   = [];
    $self->{_struct_swings}  = [];
    $self->{_seen_sh_idx}    = -1;
    $self->{_seen_sl_idx}    = -1;
    $self->{_zz_dir}         = 0;
    $self->{_zz_pivots}      = [];
    $self->{_last_hh} = $self->{_last_hl} = undef;
    $self->{_last_lh} = $self->{_last_ll} = undef;
    $self->{_bias}    = undef;
    $self->{_bh_idx}  = -1;
    $self->{_bl_idx}  = -1;
    $self->{_new_sl_since_last_up}   = 0;
    $self->{_new_sh_since_last_down} = 0;
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
    $self->_update_swing_structure;
    $self->_update_main_zigzag($i);
    $self->_detect_fvg($i);
    $self->_update_fvgs($i);
    $self->_update_obs($i);
    $self->_detect_bos_choch($i);
}

# -----------------------------------------------------------------------------
# _update_main_zigzag: ZigZag EXTERNO estilo TradingView (linea azul mayor).
# Portado de ZZMTF (© LonesomeTheBlue) y ZigZag Volume Profile (© ChartPrime).
# Cada vela puede ser swing-high (su high es el mayor de las ultimas main_prd
# velas) y/o swing-low (su low es el menor). La direccion cambia al aparecer un
# nuevo extremo del lado opuesto y cada cambio fija un pivote alternado; la
# pierna en curso se extiende hasta su extremo. CAUSAL (solo mira hacia atras)
# -> sin fuga de futuro, valido en replay. Se calcula 1 vez por vela.
# -----------------------------------------------------------------------------
sub _update_main_zigzag {
    my ($self, $i) = @_;
    my $c   = $self->{_c};
    my $cur = $c->[$i];
    my $hi  = $cur->{high};
    my $lo  = $cur->{low};

    # ¿es la vela actual el mayor high / menor low de las ultimas main_prd?
    # (equivale a ta.highest/ta.lowest con highestbars/lowestbars == 0)
    my $start = $i - $self->{main_prd} + 1;
    $start = 0 if $start < 0;
    my ($is_ph, $is_pl) = (1, 1);
    for (my $j = $start; $j < $i; $j++) {
        my $o = $c->[$j];
        $is_ph = 0 if $o->{high} >= $hi;
        $is_pl = 0 if $o->{low}  <= $lo;
        last if !$is_ph && !$is_pl;
    }
    return unless $is_ph || $is_pl;

    my $dir_prev = $self->{_zz_dir};
    my $dir      = $dir_prev;
    if    ($is_ph && !$is_pl) { $dir =  1; }
    elsif ($is_pl && !$is_ph) { $dir = -1; }
    return if $dir == 0;   # aun sin direccion definida (arranque)

    my $piv   = $self->{_zz_pivots};
    my $kind  = ($dir == 1) ? 'H' : 'L';
    my $price = ($dir == 1) ? $hi : $lo;

    if ($dir != $dir_prev || !@$piv) {
        # cambio de direccion (o primer pivote) -> NUEVA pierna del zigzag
        push @$piv, { kind => $kind, index => $i, price => $price, ts => $cur->{ts} };
        $self->{_zz_dir} = $dir;
    } else {
        # misma direccion -> EXTENDER el pivote en curso hasta su extremo
        my $last = $piv->[-1];
        my $more = ($kind eq 'H') ? ($price > $last->{price})
                                  : ($price < $last->{price});
        if ($more) {
            $last->{index} = $i;
            $last->{price} = $price;
            $last->{ts}    = $cur->{ts};
        }
    }
}

# -----------------------------------------------------------------------------
# _update_swing_structure: construye una linea estructural LIMPIA y ALTERNADA
# (ZigZag) a partir de los swings confirmados por Liquidity.
#
# La causa del "ruido" no eran los swings (ya vienen filtrados por ATR), sino
# que ANTES cada swing se convertia directamente en un pivote de la linea. Aqui,
# en cambio, la lista _struct_swings mantiene la invariante de ALTERNANCIA
# (H, L, H, L, ...) aplicando dos reglas (spec 7 y 26):
#   1) Swing del MISMO lado que el ultimo pivote -> es la misma pierna: se
#      conserva el mas relevante (high mas alto / low mas bajo), reemplazando.
#   2) Swing del lado OPUESTO -> posible pierna nueva: solo se acepta si el
#      movimiento supera struct_atr_mult*ATR y hay struct_min_bars de
#      separacion; si no, es un micro-movimiento y se descarta.
# Las etiquetas HH/HL/LH/LL y los niveles _last_* (que usa _detect_bos_choch)
# se derivan siempre de esta lista ya limpia.
# -----------------------------------------------------------------------------
sub _update_swing_structure {
    my ($self) = @_;
    my $liq = $self->{liquidity};
    return unless $liq;

    # Recolectar los swings recien confirmados en este tick.
    my @incoming;
    my $sh = $liq->last_swing_high;
    if ($sh && $sh->{index} != $self->{_seen_sh_idx}) {
        push @incoming, { kind => 'H', index => $sh->{index},
                          price => $sh->{price}, ts => $sh->{ts} };
        $self->{_seen_sh_idx} = $sh->{index};
    }
    my $sl = $liq->last_swing_low;
    if ($sl && $sl->{index} != $self->{_seen_sl_idx}) {
        push @incoming, { kind => 'L', index => $sl->{index},
                          price => $sl->{price}, ts => $sl->{ts} };
        $self->{_seen_sl_idx} = $sl->{index};
    }
    return unless @incoming;

    # Procesar en orden de indice (un mismo tick puede confirmar H y L).
    for my $sw (sort { $a->{index} <=> $b->{index} } @incoming) {
        $self->_add_structural_pivot($sw);
    }
}

# -----------------------------------------------------------------------------
# _add_structural_pivot: aplica las reglas de alternancia/relevancia/ATR.
# -----------------------------------------------------------------------------
sub _add_structural_pivot {
    my ($self, $sw) = @_;
    my $list = $self->{_struct_swings};

    if (!@$list) {
        push @$list, _mk_pivot($sw);
        $self->_after_struct_change($sw->{kind});
        return;
    }

    my $last = $list->[-1];

    # Regla 1: mismo lado -> misma pierna, conservar el extremo mas relevante.
    if ($last->{kind} eq $sw->{kind}) {
        my $more_extreme = ($sw->{kind} eq 'H')
            ? ($sw->{price} > $last->{price})
            : ($sw->{price} < $last->{price});
        if ($more_extreme) {
            $list->[-1] = _mk_pivot($sw);
            $self->_after_struct_change($sw->{kind});
        }
        return;   # menos extremo => ruido de la misma pierna, se ignora
    }

    # Regla 2: lado opuesto -> posible pierna nueva.

    # 2a) Consistencia direccional: en un zigzag, un pivote L debe quedar por
    # DEBAJO del H anterior (y un H por ENCIMA del L anterior). En rangos
    # solapados la liquidez puede confirmar un "low" por encima del high previo
    # (o viceversa): dibujar esa pierna daria un segmento invertido/plano
    # (ruido). Se ignora y se deja que el pivote actual se extienda con un swing
    # del mismo lado (p.ej. el siguiente high mas alto reemplaza al high vigente).
    my $dir_ok = ($sw->{kind} eq 'L')
        ? ($sw->{price} < $last->{price})
        : ($sw->{price} > $last->{price});
    return unless $dir_ok;

    # 2b) Significancia: el movimiento debe superar struct_atr_mult*ATR y haber
    # al menos struct_min_bars velas de separacion (evita micro-piernas).
    my $atr_vals = $self->{atr} ? $self->{atr}->get_values : undef;
    my $atr_val  = ($atr_vals && defined $atr_vals->[$sw->{index}])
                 ? $atr_vals->[$sw->{index}] : 0;
    my $min_leg  = $atr_val * $self->{struct_atr_mult};

    my $move = abs($sw->{price} - $last->{price});
    my $bars = $sw->{index} - $last->{index};
    return if ($min_leg > 0 && $move < $min_leg);
    return if ($bars < $self->{struct_min_bars});

    # 2c) Confirmacion por VOLUMEN: el pivote gana validez si su vela tiene
    # volumen >= promedio_reciente * volume_factor (tolerante si no hay volumen).
    return if ($self->{use_volume} && !$self->_volume_ok($sw->{index}));

    push @$list, _mk_pivot($sw);
    $self->_after_struct_change($sw->{kind});
}

# -----------------------------------------------------------------------------
# _volume_ok: 1 si la vela $idx tiene volumen >= volume_ma * volume_factor.
# Tolerante: si no hay datos de volumen (promedio 0) devuelve 1 (usa solo ATR).
# -----------------------------------------------------------------------------
sub _volume_ok {
    my ($self, $idx) = @_;
    my $c = $self->{_c};
    return 1 if $idx < 0 || $idx > $#$c;
    my $lo = $idx - $self->{volume_ma_period} + 1;
    $lo = 0 if $lo < 0;
    my ($sum, $n) = (0, 0);
    for my $j ($lo .. $idx) { $sum += ($c->[$j]{volume} // 0); $n++; }
    return 1 if $n == 0;
    my $ma = $sum / $n;
    return 1 if $ma <= 0;   # sin volumen -> no filtra
    return (($c->[$idx]{volume} // 0) >= $ma * $self->{volume_factor}) ? 1 : 0;
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

# _after_struct_change: reetiqueta el ultimo pivote, refresca los niveles
# estructurales vigentes y marca que hubo un swing nuevo de ese lado.
sub _after_struct_change {
    my ($self, $kind) = @_;
    $self->_relabel_last;
    $self->_recompute_last_levels;
    if ($kind eq 'H') { $self->{_new_sh_since_last_down} = 1; }
    else              { $self->{_new_sl_since_last_up}   = 1; }
}

# _relabel_last: HH/LH (o HL/LL) comparando el ultimo pivote contra el pivote
# previo del MISMO tipo en la lista ya limpia.
sub _relabel_last {
    my ($self) = @_;
    my $list = $self->{_struct_swings};
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

# _recompute_last_levels: deja en _last_hh/_last_hl/_last_lh/_last_ll el pivote
# mas reciente de cada etiqueta (los consume _detect_bos_choch). Recorre la
# lista DESDE EL FINAL y corta en cuanto encuentra los 4 -> O(k) amortizado en
# vez de O(n), clave para que el rebuild completo del replay no congele la GUI.
sub _recompute_last_levels {
    my ($self) = @_;
    my ($hh, $hl, $lh, $ll);
    my $list = $self->{_struct_swings};
    for (my $j = $#$list; $j >= 0; $j--) {
        my $p   = $list->[$j];
        my $lab = $p->{label};
        my $ref = { index => $p->{index}, price => $p->{price} };
        if    ($lab eq 'HH') { $hh //= $ref; }
        elsif ($lab eq 'LH') { $lh //= $ref; }
        elsif ($lab eq 'HL') { $hl //= $ref; }
        elsif ($lab eq 'LL') { $ll //= $ref; }
        last if $hh && $hl && $lh && $ll;
    }
    $self->{_last_hh} = $hh; $self->{_last_hl} = $hl;
    $self->{_last_lh} = $lh; $self->{_last_ll} = $ll;
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
# _detect_bos_choch: usa niveles HH/HL/LH/LL correctos segun el sesgo.
#
# Sesgo BAJISTA  → CHoCH bull si close > LH   /  BOS bear si close < LL
# Sesgo ALCISTA  → CHoCH bear si close < HL   /  BOS bull si close > HH
# Sin sesgo      → primer evento en cualquier dir establece el sesgo
#
# Cooldown anti-duplicado: entre dos BOS del mismo sentido debe haberse
# formado al menos UN swing en la direction contraria.
# -----------------------------------------------------------------------------
sub _detect_bos_choch {
    my ($self, $i) = @_;
    my $cur  = $self->{_c}[$i];
    my $bias = $self->{_bias};

    # === CONDICION ALCISTA: close por encima de un nivel estructural ===
    {
        my ($ref, $type);

        if (defined $bias && $bias eq 'bear') {
            # CHoCH bull: rompemos el ultimo LH
            $ref  = $self->{_last_lh};
            $type = 'CHoCH';
        } elsif (!defined $bias || $bias eq 'bull') {
            # BOS bull: rompemos el ultimo HH (requiere nuevo SL previo)
            $ref  = $self->{_last_hh};
            $type = 'BOS';
        }

        if ($ref && $ref->{index} != $self->{_bh_idx}
            && $cur->{close} > $ref->{price}
            && (!defined $bias || $self->{_new_sl_since_last_up}))
        {
            $self->_emit($type, 'up', $i, $ref->{price}, $ref->{index});
            $self->{_bias}   = 'bull';
            $self->{_bh_idx} = $ref->{index};
            $self->{_new_sl_since_last_up} = 0;
            return;   # un evento por vela
        }
    }

    # === CONDICION BAJISTA: close por debajo de un nivel estructural ===
    {
        my ($ref, $type);

        if (defined $bias && $bias eq 'bull') {
            # CHoCH bear: rompemos el ultimo HL
            $ref  = $self->{_last_hl};
            $type = 'CHoCH';
        } elsif (!defined $bias || $bias eq 'bear') {
            # BOS bear: rompemos el ultimo LL (requiere nuevo SH previo)
            $ref  = $self->{_last_ll};
            $type = 'BOS';
        }

        if ($ref && $ref->{index} != $self->{_bl_idx}
            && $cur->{close} < $ref->{price}
            && (!defined $bias || $self->{_new_sh_since_last_down}))
        {
            $self->_emit($type, 'down', $i, $ref->{price}, $ref->{index});
            $self->{_bias}   = 'bear';
            $self->{_bl_idx} = $ref->{index};
            $self->{_new_sh_since_last_down} = 0;
        }
    }
}

sub _emit {
    my ($self, $type, $dir, $i, $price, $origin) = @_;
    push @{ $self->{_events} }, {
        type   => $type,
        dir    => $dir,
        index  => $i,
        origin => $origin,
        ts     => $self->{_c}[$i]{ts},
        price  => $price,
        label  => $type,
    };

    # Order Block: ultimo cuerpo contra-tendencia entre origin e i-1
    my $ob_dir   = ($dir eq 'up') ? 'bull' : 'bear';
    my $ob_start = defined($origin) ? $origin : (_max(0, $i - 30));
    my $ob = $self->_find_order_block($ob_dir, $ob_start, $i - 1);
    if ($ob) {
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

sub _max { $_[0] > $_[1] ? $_[0] : $_[1] }

1;