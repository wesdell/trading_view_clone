package Market::Indicators::VolumeProfile;

# =============================================================================
# Market::Indicators::VolumeProfile   (2a fase -- Perfil de Volumen avanzado)
#
# Calcula perfiles de volumen (POC / VAH / VAL) por SEGMENTO, de forma
# incremental y sobre TODA la data hasta el cutoff (respeta Replay via
# MarketData). NO depende del Canvas. Renderiza Overlays/VolumeProfile.pm.
# NO reimplementa BOS/CHoCH: en modo estructura CONSUME los eventos confirmados
# de Indicators::SMC_Structures (get_events).
#
# MODOS:
#   'session'   -> un perfil por sesion (bucket de sesion del propio MarketData,
#                  el mismo anclaje 17:00 local que usan las velas D). Conserva
#                  perfiles historicos, no mezcla sesiones, maneja dias sin datos.
#   'bos_choch' -> un perfil por intervalo entre eventos BOS/CHoCH CONFIRMADOS de
#                  SMC (scope configurable). Ancla = ts exacto del evento. No usa
#                  eventos no confirmados (cursor por confirmed ts). Sin duplicar.
#   Contingencia -> si el segmento vigente no tiene historial suficiente
#                  (min_history_bars) se retrocede al ultimo inicio de sesion /
#                  ultimo evento macro confirmado; se marca contingency+razon; no
#                  se fabrica volumen; nunca falla en silencio.
#
# DISTRIBUCION (documentada): precio min/max del segmento; nbins bins; volumen de
# cada vela repartido UNIFORME entre los bins que cubre [low,high] (sin intrabar);
# POC=bin de mayor volumen (empate: mas cercano al medio, luego indice menor);
# Value Area=va_pct (0.70) por expansion greedy de 1 bin desde el POC (empate ->
# lado superior); VAH/VAL=bordes de los bins extremos de la VA; velas con
# volume<=0 no contribuyen (no se inventa); segmento sin volumen => incomplete.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %a) = @_;
    my $self = {
        nbins            => $a{nbins}            // 50,
        va_pct           => $a{va_pct}           // 0.70,
        mode             => $a{mode}             // 'session',
        anchor_scope     => exists $a{anchor_scope} ? $a{anchor_scope} : 'external',
        session_tf       => $a{session_tf}       // 'D',
        min_history_bars => $a{min_history_bars} // 20,
        smc              => $a{smc},

        _c            => [],
        _profiles     => [],   # perfiles CERRADOS (historicos), en orden
        _seg          => [],   # velas del segmento en curso
        _seg_i        => [],   # indices globales paralelos a _seg (para el render)
        _seg_anchor   => undef,# {ts, kind, dir}
        _smc_seen     => 0,    # cursor de eventos SMC (modo bos_choch)
        _next_id      => 1,
        _market_data  => undef,
    };
    bless $self, $class;
    return $self;
}

sub get_values       { return []; }
sub get_market_data  { return $_[0]->{_market_data}; }
sub set_mode { my ($s,$m)=@_; $s->{mode}=$m; }

sub reset {
    my ($self) = @_;
    $self->{_c} = []; $self->{_profiles} = []; $self->{_seg} = []; $self->{_seg_i} = [];
    $self->{_seg_anchor} = undef; $self->{_smc_seen} = 0;
    $self->{_next_id} = 1; $self->{_market_data} = undef;
}

sub update_last {
    my ($self, $md) = @_;
    my $i = $md->last_index; return if $i < 0;
    $self->update_at_index($md, $i);
}

sub update_at_index {
    my ($self, $md, $i) = @_;
    my $c = $md->get_candle($i); return unless defined $c;
    $self->{_market_data} = $md;
    push @{ $self->{_c} }, $c;

    if ($self->{mode} eq 'bos_choch') { $self->_step_bos_choch($md, $i, $c); }
    else                              { $self->_step_session($md, $i, $c); }
}

# ---- modo SESION: segmenta por el bucket de sesion del MarketData ----
sub _step_session {
    my ($self, $md, $i, $c) = @_;
    my $skey = $self->_session_key($md, $c->{ts});
    if (defined $self->{_seg_anchor} && $self->{_seg_anchor}{ts} != $skey) {
        $self->_close_segment('session');   # cierra la sesion anterior (no mezcla)
    }
    $self->{_seg_anchor} //= { ts => $skey, kind => 'session', dir => undef };
    push @{ $self->{_seg} },   $c;
    push @{ $self->{_seg_i} }, $i;
}

# ---- modo BOS/CHoCH: segmenta por eventos CONFIRMADOS de SMC ----
sub _step_bos_choch {
    my ($self, $md, $i, $c) = @_;
    $self->{_seg_anchor} //= { ts => $c->{ts}, kind => 'start', dir => undef };
    my $ev = $self->{smc} ? $self->{smc}->get_events : [];
    while ($self->{_smc_seen} < scalar(@$ev)) {
        my $e = $ev->[ $self->{_smc_seen} ];
        last if $e->{ts} > $c->{ts};                       # aun no confirmado (sin futuro)
        $self->{_smc_seen}++;
        next if defined $self->{anchor_scope} && ($e->{scope}//'') ne $self->{anchor_scope};
        # cierra el perfil hasta el ancla y abre uno nuevo anclado en el evento
        $self->_close_segment('bos_choch');
        $self->{_seg_anchor} = { ts => $e->{ts}, kind => $e->{type}, dir => $e->{dir} };
    }
    push @{ $self->{_seg} },   $c;
    push @{ $self->{_seg_i} }, $i;
}

# cierra el segmento en curso -> perfil historico
sub _close_segment {
    my ($self, $mode) = @_;
    return unless @{ $self->{_seg} };
    my $p = $self->_finalize($self->{_seg}, $self->{_seg_i}, $self->{_seg_anchor}, $mode, 'closed');
    push @{ $self->{_profiles} }, $p if $p;
    $self->{_seg} = []; $self->{_seg_i} = [];
    $self->{_seg_anchor} = undef;
}

# clave de sesion: reutiliza el bucketing de sesion del MarketData (mismo anclaje
# que las velas D). Fallback: dia local UTC-5 anclado a 17:00 si no existe.
sub _session_key {
    my ($self, $md, $ts) = @_;
    return $md->_bucket_ts_for($ts, $self->{session_tf}) if $md->can('_bucket_ts_for');
    return int(($ts - 17*3600 + 5*3600) / 86400);   # fallback determinista
}

# =============================================================================
# ACCESORES: perfiles cerrados + el ABIERTO (recomputado desde _seg, no depende
# del zoom). get_active_profile aplica la contingencia.
# =============================================================================
sub get_profiles {
    my ($self) = @_;
    my @out = @{ $self->{_profiles} };
    if (@{ $self->{_seg} }) {
        my $open = $self->_finalize($self->{_seg}, $self->{_seg_i}, $self->{_seg_anchor}, $self->{mode}, 'open');
        push @out, $open if $open;
    }
    return \@out;
}

sub contingency_active { return $_[0]->{_contingency} ? 1 : 0; }

# get_active_profile: el perfil relevante al cutoff (el abierto). Si su historial
# es insuficiente (< min_history_bars), CONTINGENCIA: retrocede al ultimo inicio
# de sesion / ultimo evento macro confirmado y marca contingency+razon.
sub get_active_profile {
    my ($self) = @_;
    $self->{_contingency} = 0;
    my @seg  = @{ $self->{_seg} };
    my @segi = @{ $self->{_seg_i} };
    my $anchor = $self->{_seg_anchor};
    my $reason;

    if (scalar(@seg) < $self->{min_history_bars}) {
        $self->{_contingency} = 1;
        if (@{ $self->{_profiles} }) {
            # fallback: ultimo inicio de sesion / ultimo evento macro confirmado
            my $prev = $self->{_profiles}[-1];
            @seg  = (@{ $prev->{_candles} }, @seg);
            @segi = (@{ $prev->{_idxs} },    @segi);
            $anchor = $prev->{anchor};
            $reason = 'historial_reciente_insuficiente:usar_ultimo_ancla';
        } elsif (@seg) {
            # sin ancla previa: se usa lo disponible SIN fabricar (perfil corto)
            $reason = 'historial_insuficiente:sin_fallback';
        } else {
            $reason = 'sin_datos';   # ni datos ni fallback: no falla, perfil vacio
        }
    }
    my $p = $self->_finalize(\@seg, \@segi, $anchor, $self->{mode}, 'active');
    # sin datos: perfil vacio explicito (no falla en silencio, no fabrica)
    $p //= { mode=>$self->{mode}, state=>'active', incomplete=>1,
             bins=>[], total_volume=>0, poc_price=>undef, vah=>undef, val=>undef };
    $p->{contingency}        = $self->{_contingency};
    $p->{contingency_reason} = $reason;
    return $p;
}

# =============================================================================
# NUCLEO: binning + POC + Value Area (compartido por todos los modos).
# =============================================================================
sub _finalize {
    my ($self, $candles, $idxs, $anchor, $mode, $state) = @_;
    return undef unless $candles && @$candles;

    my ($pmin, $pmax) = (9e18, -9e18);
    for my $c (@$candles) { $pmin = $c->{low} if $c->{low} < $pmin; $pmax = $c->{high} if $c->{high} > $pmax; }

    my $prof = {
        id        => $self->{_next_id}++,
        mode      => $mode,
        anchor    => $anchor,
        anchor_ts => $anchor ? $anchor->{ts} : $candles->[0]{ts},
        anchor_kind => $anchor ? $anchor->{kind} : undef,
        anchor_dir  => $anchor ? $anchor->{dir}  : undef,
        start_ts  => $candles->[0]{ts},
        end_ts    => $candles->[-1]{ts},
        start_idx => ($idxs && @$idxs) ? $idxs->[0]  : undef,
        end_idx   => ($idxs && @$idxs) ? $idxs->[-1] : undef,
        price_min => $pmin, price_max => $pmax,
        nbins     => $self->{nbins}, va_pct => $self->{va_pct},
        state     => $state, incomplete => 0,
        contingency => 0, contingency_reason => undef,
        _candles  => $candles,   # para la contingencia (fusion con previo)
        _idxs     => $idxs,
    };

    if ($pmax <= $pmin) { $prof->{incomplete} = 1; return $prof; }  # sin rango: no fabrica

    my $nb = $self->{nbins};
    my $binsize = ($pmax - $pmin) / $nb;
    my @bins = (0) x $nb;
    my $total = 0;
    for my $c (@$candles) {
        next if !defined $c->{volume} || $c->{volume} <= 0;    # incompleto: no contribuye
        my $blo = int(($c->{low}  - $pmin) / $binsize); $blo = 0      if $blo < 0;   $blo = $nb-1 if $blo > $nb-1;
        my $bhi = int(($c->{high} - $pmin) / $binsize); $bhi = 0      if $bhi < 0;   $bhi = $nb-1 if $bhi > $nb-1;
        my $n = $bhi - $blo + 1;
        my $share = $c->{volume} / $n;
        $bins[$_] += $share for $blo .. $bhi;
        $total += $c->{volume};
    }
    $prof->{binsize} = $binsize; $prof->{bins} = \@bins; $prof->{total_volume} = $total;

    if ($total <= 0) { $prof->{incomplete} = 1; return $prof; }   # sin volumen real

    my ($poc, $lo, $hi, $va_vol) = $self->_value_area(\@bins, $total);
    $prof->{poc_bin}   = $poc;
    $prof->{poc_low}   = $pmin + $poc * $binsize;
    $prof->{poc_high}  = $pmin + ($poc+1) * $binsize;
    $prof->{poc_price} = $pmin + ($poc+0.5) * $binsize;
    $prof->{val}       = $pmin + $lo * $binsize;
    $prof->{vah}       = $pmin + ($hi+1) * $binsize;
    $prof->{va_volume} = $va_vol;
    return $prof;
}

# POC + Value Area. POC: max volumen (empate -> mas cercano al medio, luego menor
# indice). VA: expansion greedy de 1 bin desde el POC (empate -> lado superior).
sub _value_area {
    my ($self, $bins, $total) = @_;
    my $nb = scalar @$bins;
    my $poc = 0; my $best = $bins->[0]; my $mid = ($nb-1)/2;
    for my $b (1 .. $nb-1) {
        if ($bins->[$b] > $best
            || ($bins->[$b] == $best && abs($b-$mid) < abs($poc-$mid))) {
            $best = $bins->[$b]; $poc = $b;
        }
    }
    my ($lo, $hi) = ($poc, $poc);
    my $va = $bins->[$poc];
    my $target = $self->{va_pct} * $total;
    while ($va < $target && ($lo > 0 || $hi < $nb-1)) {
        my $up = ($hi < $nb-1) ? $bins->[$hi+1] : -1;
        my $dn = ($lo > 0)     ? $bins->[$lo-1] : -1;
        last if $up < 0 && $dn < 0;
        if ($up >= $dn) { $hi++; $va += $bins->[$hi]; }   # empate -> lado superior
        else            { $lo--; $va += $bins->[$lo]; }
    }
    return ($poc, $lo, $hi, $va);
}

1;
