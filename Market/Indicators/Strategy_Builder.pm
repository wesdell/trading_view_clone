package Market::Indicators::Strategy_Builder;

# =============================================================================
# Market::Indicators::Strategy_Builder   (Tabla 1 del PDF, 2a fase)
#
# Motor de calculo del DIY Custom Strategy Builder. Calcula, por vela CERRADA y
# de forma incremental (sin depender del Canvas ni de las velas visibles), los
# 5 componentes obligatorios y un COMBINADOR de condiciones de entrada/salida.
# NO reimplementa indicadores de la 1a fase: reutiliza Market::Indicators::ATR.
# Contrato IndicatorManager: new / update_at_index / update_last / get_values /
# reset. Renderiza Overlays/Strategy_Builder.pm (separacion calculo/render).
#
# FORMULAS (variantes publicas documentadas; para HalfTrend/RangeFilter/Supply-
# Demand NO se afirma equivalencia con ningun script protegido, se usan como
# CONTRATO DE COMPORTAMIENTO):
#
# 1) SUPERTREND  -- algoritmo oficial de TradingView `ta.supertrend(factor,len)`:
#      src=hl2 ; atr=ATR(st_period) ; upper=src+factor*atr ; lower=src-factor*atr
#      lower := (lower>lower[1] or close[1]<lower[1]) ? lower : lower[1]
#      upper := (upper<upper[1] or close[1]>upper[1]) ? upper : upper[1]
#      dir   := prevST==upper[1] ? (close>upper?-1:1) : (close<lower?1:-1)  (-1=alza)
#      st    := dir==-1 ? lower : upper
#    ATR = replica Wilder (Market::Indicators::ATR) => equivalencia numerica con
#    ta.atr para velas >= st_period (durante el calentamiento puede diferir).
#
# 2) HALFTREND  -- variante "everget" (amplitude, channelDeviation, ATR(100)/2):
#      highPrice=highest(high,amp) ; lowPrice=lowest(low,amp)
#      highma=SMA(high,amp) ; lowma=SMA(low,amp) ; dev=channelDev*ATR(100)/2
#      alterna trend 0(alcista)/1(bajista) segun cruce de medias contra
#      max/minPrice + confirmacion con close vs high/low previos. Linea = up/down.
#
# 3) RANGE FILTER  -- variante "DonovanWall" (sampling per, mult):
#      smoothrng(x,t,m)=EMA(EMA(|x-x[1]|,t), t*2-1)*m
#      rng=smoothrng(close,per,mult)
#      filt := close>filt[1] ? max(filt[1],close-rng) : min(filt[1],close+rng)
#      dir = filt>filt[1]?+1 : filt<filt[1]?-1 : dir[1]  (acumulacion/distribucion)
#      EMA sembrada con el primer valor (variante documentada).
#
# 4/5) SUPPLY / DEMAND ZONES  -- zona en el ORIGEN de una vela de impulso
#      validada por volumen:
#      impulso alcista i: close>open & |close-open|>sd_impulse_atr*ATR(14) &
#        vol>sd_vol_factor*SMA(vol,sd_vol_period) => DEMAND=[low[i],open[i]]
#      impulso bajista i: analogo => SUPPLY=[open[i],high[i]]
#      estados: active -> mitigated (precio testea la zona) -> invalidated
#      (cierre atraviesa la zona). id estable, sin duplicar zonas activas
#      solapadas del mismo tipo. Integra Replay (rebuild determinista).
#
# COMBINADOR (no es un DSL): set_rules({ entry=>{conds=>[..],mode=>'AND'|'OR',
# side=>'long'|'short'}, exit=>{...} }). Condiciones disponibles (get_conditions):
#   st_up st_down st_flip_up st_flip_down ht_up ht_down ht_flip_up ht_flip_down
#   rf_up rf_down rf_flat in_demand in_supply. Evalua por vela confirmada y emite
#   senales {kind,side,index,ts,conds}. Sin futuro; se reinicia con reset().
# =============================================================================

use strict;
use warnings;
use Market::Indicators::ATR;

sub new {
    my ($class, %a) = @_;
    my $self = {
        # SuperTrend
        st_period => $a{st_period} // 10,
        st_factor => $a{st_factor} // 3.0,
        # HalfTrend (everget)
        ht_amp      => $a{ht_amplitude}   // 2,
        ht_chan_dev => $a{ht_channel_dev} // 2,
        ht_atr_len  => $a{ht_atr_period}  // 100,
        # Range Filter (DonovanWall)
        rf_per  => $a{rf_period} // 100,
        rf_mult => $a{rf_mult}   // 3.0,
        # Supply/Demand
        sd_impulse_atr => $a{sd_impulse_atr} // 1.5,
        sd_vol_factor  => $a{sd_vol_factor}  // 1.5,
        sd_vol_period  => $a{sd_vol_period}  // 20,
        sd_max_zones   => $a{sd_max_zones}   // 60,

        rules => $a{rules} // { entry => undef, exit => undef },

        _c   => [],
        _st  => [],   # {value,dir(+1/-1),flip(+1/-1/0)}
        _ht  => [],
        _rf  => [],
        _supply => [], _demand => [],
        _active_supply => [], _active_demand => [],
        _signals => [],
        _next_zone_id => 1,
        _market_data  => undef,

        # ATR reutilizado (1a fase) -- una instancia por periodo requerido.
        _atr_st => Market::Indicators::ATR->new($a{st_period}  // 10),
        _atr_ht => Market::Indicators::ATR->new($a{ht_atr_period} // 100),
        _atr_sd => Market::Indicators::ATR->new(14),

        _st_state => {},
        _ht_state => { trend => 0, next_trend => 0,
                       max_low => undef, min_high => undef, up => undef, down => undef },
        _rf_state => { ema => {}, filt => undef, dir => 0 },
    };
    bless $self, $class;
    return $self;
}

# ---- accesores de solo lectura ----
sub get_values        { return $_[0]->{_st}; }   # linea SuperTrend (paralela a velas)
sub get_supertrend    { return $_[0]->{_st}; }
sub get_halftrend     { return $_[0]->{_ht}; }
sub get_rangefilter   { return $_[0]->{_rf}; }
sub get_supply_zones  { return $_[0]->{_supply}; }
sub get_demand_zones  { return $_[0]->{_demand}; }
sub get_signals       { return $_[0]->{_signals}; }
sub get_market_data   { return $_[0]->{_market_data}; }
sub get_conditions {
    return [qw(st_up st_down st_flip_up st_flip_down
               ht_up ht_down ht_flip_up ht_flip_down
               rf_up rf_down rf_flat in_demand in_supply)];
}

sub set_rules {
    my ($self, $rules) = @_;
    $self->{rules} = $rules;
    # re-evaluar senales sobre el estado ya calculado (no recalcula componentes).
    $self->_reeval_signals;
    return;
}

sub reset {
    my ($self) = @_;
    $self->{_c} = []; $self->{_st} = []; $self->{_ht} = []; $self->{_rf} = [];
    $self->{_supply} = []; $self->{_demand} = [];
    $self->{_active_supply} = []; $self->{_active_demand} = [];
    $self->{_signals} = [];
    $self->{_next_zone_id} = 1;
    $self->{_market_data}  = undef;
    $self->{_atr_st}->reset; $self->{_atr_ht}->reset; $self->{_atr_sd}->reset;
    $self->{_st_state} = {};
    $self->{_ht_state} = { trend => 0, next_trend => 0,
                           max_low => undef, min_high => undef, up => undef, down => undef };
    $self->{_rf_state} = { ema => {}, filt => undef, dir => 0 };
}

sub update_last {
    my ($self, $md) = @_;
    my $idx = $md->last_index;
    return if $idx < 0;
    $self->update_at_index($md, $idx);
}

sub update_at_index {
    my ($self, $md, $i) = @_;
    my $c = $md->get_candle($i);
    return unless defined $c;
    $self->{_market_data} = $md;
    push @{ $self->{_c} }, $c;

    # ATR reutilizado (1a fase): se alimenta con la misma vela.
    $self->{_atr_st}->update_at_index($md, $i);
    $self->{_atr_ht}->update_at_index($md, $i);
    $self->{_atr_sd}->update_at_index($md, $i);

    $self->_calc_supertrend($i);
    $self->_calc_halftrend($i);
    $self->_calc_rangefilter($i);
    $self->_calc_supply_demand($i);
    $self->_update_zones($i);
    $self->_eval_signals($i);
}

# =============================================================================
# 1) SUPERTREND (oficial ta.supertrend)
# =============================================================================
sub _calc_supertrend {
    my ($self, $i) = @_;
    my $c   = $self->{_c}[$i];
    my $atr = $self->{_atr_st}->get_values->[$i];
    my $s   = $self->{_st_state};
    unless (defined $atr) { push @{ $self->{_st} }, { value=>undef, dir=>0, flip=>0 }; return; }

    my $src = ($c->{high} + $c->{low}) / 2;
    my $ub  = $src + $self->{st_factor} * $atr;
    my $lb  = $src - $self->{st_factor} * $atr;

    my $plb = defined $s->{lb} ? $s->{lb} : $lb;
    my $pub = defined $s->{ub} ? $s->{ub} : $ub;
    my $pclose = ($i >= 1) ? $self->{_c}[$i-1]{close} : $c->{close};

    $lb = ($lb > $plb || $pclose < $plb) ? $lb : $plb;
    $ub = ($ub < $pub || $pclose > $pub) ? $ub : $pub;

    my $dir;   # -1 = tendencia alcista (linea=lb) ; 1 = bajista (linea=ub)
    if (!defined $s->{st}) { $dir = 1; }
    elsif ($s->{st} == $pub) { $dir = ($c->{close} > $ub) ? -1 : 1; }
    else                     { $dir = ($c->{close} < $lb) ?  1 : -1; }

    my $stline = ($dir == -1) ? $lb : $ub;
    my $my_dir = ($dir == -1) ? 1 : -1;                 # +1 up / -1 down
    my $prev   = @{ $self->{_st} } ? $self->{_st}[-1]{dir} : 0;
    my $flip   = ($prev != 0 && $my_dir != $prev) ? $my_dir : 0;

    @{$s}{qw(lb ub st)} = ($lb, $ub, $stline);
    push @{ $self->{_st} }, { value=>$stline, dir=>$my_dir, flip=>$flip };
}

# =============================================================================
# 2) HALFTREND (everget)
# =============================================================================
sub _calc_halftrend {
    my ($self, $i) = @_;
    my $amp = $self->{ht_amp};
    my $c   = $self->{_c};
    unless ($i >= $amp) { push @{ $self->{_ht} }, { value=>undef, dir=>0, flip=>0 }; return; }

    my $atr = $self->{_atr_ht}->get_values->[$i];
    my $dev = defined $atr ? $self->{ht_chan_dev} * ($atr/2) : 0;

    my ($hh,$ll,$sh,$sl) = (-9e18, 9e18, 0, 0);
    for my $j (($i-$amp+1) .. $i) {
        $hh = $c->[$j]{high} if $c->[$j]{high} > $hh;
        $ll = $c->[$j]{low}  if $c->[$j]{low}  < $ll;
        $sh += $c->[$j]{high}; $sl += $c->[$j]{low};
    }
    my $highma = $sh/$amp; my $lowma = $sl/$amp;
    my $s = $self->{_ht_state};
    $s->{max_low}  = $c->[$i-1]{low}  unless defined $s->{max_low};
    $s->{min_high} = $c->[$i-1]{high} unless defined $s->{min_high};
    my $prev_trend = $s->{trend};

    if ($s->{next_trend} == 1) {
        $s->{max_low} = $ll > $s->{max_low} ? $ll : $s->{max_low};   # max(lowPrice, maxLow)
        if ($highma < $s->{max_low} && $c->[$i]{close} < $c->[$i-1]{low}) {
            $s->{trend} = 1; $s->{next_trend} = 0; $s->{min_high} = $hh;
        }
    } else {
        $s->{min_high} = $hh < $s->{min_high} ? $hh : $s->{min_high};
        if ($lowma > $s->{min_high} && $c->[$i]{close} > $c->[$i-1]{high}) {
            $s->{trend} = 0; $s->{next_trend} = 1; $s->{max_low} = $ll;
        }
    }

    if ($s->{trend} == 0) {
        if (defined $prev_trend && $prev_trend != 0) { $s->{up} = defined $s->{down} ? $s->{down} : $s->{up}; }
        else { $s->{up} = defined $s->{up} ? ($s->{max_low} > $s->{up} ? $s->{max_low} : $s->{up}) : $s->{max_low}; }
    } else {
        if (defined $prev_trend && $prev_trend != 1) { $s->{down} = defined $s->{up} ? $s->{up} : $s->{down}; }
        else { $s->{down} = defined $s->{down} ? ($s->{min_high} < $s->{down} ? $s->{min_high} : $s->{down}) : $s->{min_high}; }
    }

    my $line   = ($s->{trend} == 0) ? $s->{up} : $s->{down};
    my $my_dir = ($s->{trend} == 0) ? 1 : -1;                  # +1 up / -1 down
    my $prev   = @{ $self->{_ht} } ? $self->{_ht}[-1]{dir} : 0;
    my $flip   = ($prev != 0 && $my_dir != $prev) ? $my_dir : 0;
    push @{ $self->{_ht} }, { value=>$line, dir=>$my_dir, flip=>$flip, dev=>$dev };
}

# =============================================================================
# 3) RANGE FILTER (DonovanWall)
# =============================================================================
sub _ema {
    my ($self, $key, $x, $n) = @_;
    my $e = $self->{_rf_state}{ema};
    my $alpha = 2 / ($n + 1);
    if (!defined $e->{$key}) { $e->{$key} = $x; }              # semilla = 1er valor
    else { $e->{$key} = $e->{$key} + $alpha * ($x - $e->{$key}); }
    return $e->{$key};
}

sub _calc_rangefilter {
    my ($self, $i) = @_;
    my $c = $self->{_c};
    my $src = $c->[$i]{close};
    my $s   = $self->{_rf_state};
    # Cada punto conserva: ts (timestamp), value (filtro), dir (direccion
    # confirmada +1 alcista/-1 bajista/persistente en plano), flip (cambio de
    # direccion confirmado). NO se altera ningun valor matematico.
    if ($i < 1) { push @{ $self->{_rf} }, { ts=>$c->[$i]{ts}, value=>$src, dir=>0, flip=>0 }; $s->{filt}=$src; return; }

    my $per  = $self->{rf_per};
    my $absd = abs($src - $c->[$i-1]{close});
    my $avrng = $self->_ema('avrng', $absd, $per);
    my $rng   = $self->_ema('smooth', $avrng, $per*2 - 1) * $self->{rf_mult};

    my $pf = defined $s->{filt} ? $s->{filt} : $src;
    my $filt;
    if ($src > $pf) { my $t = $src - $rng; $filt = ($t < $pf) ? $pf : $t; }
    else            { my $t = $src + $rng; $filt = ($t > $pf) ? $pf : $t; }

    my $dir = ($filt > $pf) ? 1 : ($filt < $pf) ? -1 : $s->{dir};
    my $prev = @{ $self->{_rf} } ? $self->{_rf}[-1]{dir} : 0;
    my $flip = ($prev != 0 && $dir != 0 && $dir != $prev) ? $dir : 0;

    $s->{filt} = $filt; $s->{dir} = $dir;
    push @{ $self->{_rf} }, { ts=>$c->[$i]{ts}, value=>$filt, dir=>$dir, flip=>$flip, rng=>$rng };
}

# =============================================================================
# 4/5) SUPPLY / DEMAND
# =============================================================================
sub _calc_supply_demand {
    my ($self, $i) = @_;
    my $c = $self->{_c};
    my $p = $self->{sd_vol_period};
    return if $i < $p;   # necesita media de volumen

    my $atr = $self->{_atr_sd}->get_values->[$i];
    return unless defined $atr && $atr > 0;

    my $vol_sum = 0; $vol_sum += $c->[$_]{volume} for ($i-$p+1 .. $i);
    my $vol_avg = $vol_sum / $p;
    my $cd = $c->[$i];
    my $body = abs($cd->{close} - $cd->{open});
    return if $body < $self->{sd_impulse_atr} * $atr;         # sin impulso
    return if $cd->{volume} < $self->{sd_vol_factor} * $vol_avg;   # sin volumen validante

    my ($kind, $zlow, $zhigh);
    if ($cd->{close} > $cd->{open}) { ($kind,$zlow,$zhigh) = ('demand', $cd->{low},  $cd->{open}); }
    else                            { ($kind,$zlow,$zhigh) = ('supply', $cd->{open}, $cd->{high}); }
    return if $zhigh - $zlow <= 0;

    my $list   = ($kind eq 'demand') ? $self->{_active_demand} : $self->{_active_supply};
    # sin duplicar: no crear si solapa una zona ACTIVA del mismo tipo
    for my $z (@$list) {
        next unless $z->{state} eq 'active';
        return if !($zhigh < $z->{zone_low} || $zlow > $z->{zone_high});   # solapan
    }

    my $zone = {
        id => $self->{_next_zone_id}++, kind => $kind,
        zone_low => $zlow, zone_high => $zhigh,
        idx => $i, ts => $cd->{ts}, state => 'active',
        mitig_at => undef, invalid_at => undef,
        mitig_ts => undef, invalid_ts => undef,   # timestamps de fin de ciclo
        volume => $cd->{volume}, vol_avg => $vol_avg, atr => $atr,
        # fortaleza = cuanto supero el volumen del impulso a su media (sin inventar:
        # deriva de datos ya calculados; sirve de criterio de prioridad/etiqueta).
        strength => ($vol_avg > 0 ? $cd->{volume} / $vol_avg : 0),
    };
    if ($kind eq 'demand') { push @{ $self->{_demand} }, $zone; push @{ $self->{_active_demand} }, $zone; }
    else                   { push @{ $self->{_supply} }, $zone; push @{ $self->{_active_supply} }, $zone; }

    # cap del working set de zonas activas
    for my $ak ('_active_demand','_active_supply') {
        my $r = $self->{$ak};
        splice(@$r, 0, @$r - $self->{sd_max_zones}) if @$r > $self->{sd_max_zones};
    }
}

sub _update_zones {
    my ($self, $i) = @_;
    my $cd = $self->{_c}[$i];
    for my $ak ('_active_demand','_active_supply') {
        my @keep;
        for my $z (@{ $self->{$ak} }) {
            # Aun no evaluable (vela de creacion): CONSERVARLA en el working set.
            # (Un `next` a secas la sacaba de @keep -> la zona se caia del working
            #  set en su propia vela y no volvia a evaluarse nunca: quedaba
            #  'active' para siempre y el overlay la dibujaba indefinidamente.)
            if ($i <= $z->{idx}) { push @keep, $z; next; }
            if ($z->{kind} eq 'demand') {
                if ($cd->{close} < $z->{zone_low}) { $z->{state}='invalidated'; $z->{invalid_at}=$i; $z->{invalid_ts}=$cd->{ts}; next; }
                if ($cd->{low} <= $z->{zone_high} && $z->{state} eq 'active') { $z->{state}='mitigated'; $z->{mitig_at}=$i; $z->{mitig_ts}=$cd->{ts}; }
            } else {
                if ($cd->{close} > $z->{zone_high}) { $z->{state}='invalidated'; $z->{invalid_at}=$i; $z->{invalid_ts}=$cd->{ts}; next; }
                if ($cd->{high} >= $z->{zone_low} && $z->{state} eq 'active') { $z->{state}='mitigated'; $z->{mitig_at}=$i; $z->{mitig_ts}=$cd->{ts}; }
            }
            push @keep, $z;
        }
        $self->{$ak} = \@keep;
    }
}

# =============================================================================
# COMBINADOR
# =============================================================================
sub _cond {
    my ($self, $name, $i) = @_;
    my $st = $self->{_st}[$i]; my $ht = $self->{_ht}[$i]; my $rf = $self->{_rf}[$i];
    my $close = $self->{_c}[$i]{close};
    return 0 unless $st && $ht && $rf;
    if    ($name eq 'st_up')       { return $st->{dir} == 1  ? 1 : 0; }
    elsif ($name eq 'st_down')     { return $st->{dir} == -1 ? 1 : 0; }
    elsif ($name eq 'st_flip_up')  { return $st->{flip} == 1  ? 1 : 0; }
    elsif ($name eq 'st_flip_down'){ return $st->{flip} == -1 ? 1 : 0; }
    elsif ($name eq 'ht_up')       { return $ht->{dir} == 1  ? 1 : 0; }
    elsif ($name eq 'ht_down')     { return $ht->{dir} == -1 ? 1 : 0; }
    elsif ($name eq 'ht_flip_up')  { return $ht->{flip} == 1  ? 1 : 0; }
    elsif ($name eq 'ht_flip_down'){ return $ht->{flip} == -1 ? 1 : 0; }
    elsif ($name eq 'rf_up')       { return $rf->{dir} == 1  ? 1 : 0; }
    elsif ($name eq 'rf_down')     { return $rf->{dir} == -1 ? 1 : 0; }
    elsif ($name eq 'rf_flat')     { return $rf->{dir} == 0  ? 1 : 0; }
    elsif ($name eq 'in_demand')   { return $self->_in_zone('_active_demand', $close) ? 1 : 0; }
    elsif ($name eq 'in_supply')   { return $self->_in_zone('_active_supply', $close) ? 1 : 0; }
    return 0;
}

sub _in_zone {
    my ($self, $ak, $price) = @_;
    for my $z (@{ $self->{$ak} }) {
        next if $z->{state} eq 'invalidated';
        return 1 if $price >= $z->{zone_low} && $price <= $z->{zone_high};
    }
    return 0;
}

sub _combine {
    my ($self, $rule, $i) = @_;
    return (0, []) unless $rule && $rule->{conds} && @{ $rule->{conds} };
    my $mode = $rule->{mode} // 'AND';
    my @met;
    my $res = ($mode eq 'AND') ? 1 : 0;
    for my $name (@{ $rule->{conds} }) {
        my $v = $self->_cond($name, $i);
        push @met, $name if $v;
        if ($mode eq 'AND') { $res = 0 unless $v; }
        else                { $res = 1 if $v; }
    }
    return ($res, \@met);
}

sub _eval_signals {
    my ($self, $i) = @_;
    for my $kind ('entry','exit') {
        my $rule = $self->{rules}{$kind} or next;
        my ($ok, $met) = $self->_combine($rule, $i);
        next unless $ok;
        push @{ $self->{_signals} }, {
            kind => $kind, side => ($rule->{side} // 'long'),
            index => $i, ts => $self->{_c}[$i]{ts},
            conds => $met,
        };
    }
}

# _reeval_signals: recomputa SOLO las senales (no los componentes) al cambiar las
# reglas del combinador, sobre el estado ya calculado.
sub _reeval_signals {
    my ($self) = @_;
    $self->{_signals} = [];
    $self->_eval_signals($_) for 0 .. $#{ $self->{_c} };
}

1;
