package Market::Indicators::AnchoredVWAP;

# =============================================================================
# Market::Indicators::AnchoredVWAP   (2a fase -- Anchored VWAP multipivote)
#
# VWAP anclado con MULTIPLES anclas simultaneas (acumulados independientes, sin
# mezclar). Incremental, sobre TODA la data desde cada ancla hasta el cutoff
# (respeta Replay via MarketData). NO depende del Canvas. NO reimplementa BOS/
# CHoCH ni el Volume Profile: CONSUME sus salidas confirmadas.
#
# FORMULA (documentada): src=hlc3 (configurable close/hl2/hlc3/ohlc4);
#   cum_pv += src*volume ; cum_v += volume ; vwap = cum_pv/cum_v.
#   volumen 0 => suma 0 (no altera); cum_v==0 => value=undef (no fabrica).
#   Reinicio EXACTO en la vela del ancla (para POC, desde la vela de control del
#   perfil, acumulando hacia adelante). Sin redondeo intermedio.
#
# ANCLAS (5 tipos): 'session' (apertura ETH = bucket de sesion del MarketData),
#   'open' (apertura oficial, minuto local configurable, distinta del inicio
#   ETH), 'BOS' y 'CHoCH' (eventos CONFIRMADOS de SMC, ancla en la vela de
#   confirmacion), 'POC' (vela de control del ultimo perfil CERRADO del Volume
#   Profile validado). Una activa por tipo (la anterior del mismo tipo pasa a
#   inactive, congelada). Sin duplicar (cursores/flags). reset() limpia todo
#   (cambio de simbolo/TF). Sin futuro (solo eventos con ts <= vela actual).
#
# Cada ancla conserva: id, type, ts, tf, anchor_price, cum_pv, cum_v, value,
# state (active|inactive), origin, start_idx, end_ts.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %a) = @_;
    my $self = {
        src              => $a{src}              // 'hlc3',
        session_tf       => $a{session_tf}       // 'D',
        official_open_min=> $a{official_open_min}// 510,   # 08:30 local (-05:00) = RTH / cash open
        local_offset_sec => $a{local_offset_sec} // -5*3600,
        anchor_scope     => exists $a{anchor_scope} ? $a{anchor_scope} : 'external',
        max_inactive     => $a{max_inactive}     // 24,
        smc              => $a{smc},
        vp               => $a{vp},

        _c            => [],
        _anchors      => [],
        _next_id      => 1,
        _tf           => undef,
        _cur_skey     => undef,
        _seen_open    => 0,
        _prev_lmin    => undef,   # minuto local de la vela previa (deteccion por cruce)
        _smc_seen     => 0,
        _vp_seen      => 0,
        _market_data  => undef,
    };
    bless $self, $class;
    return $self;
}

sub get_values      { return []; }
sub get_anchors     { return $_[0]->{_anchors}; }
sub get_active      { return [ grep { $_->{state} eq 'active' } @{ $_[0]->{_anchors} } ]; }
sub get_market_data { return $_[0]->{_market_data}; }

sub reset {
    my ($self) = @_;
    $self->{_c} = []; $self->{_anchors} = []; $self->{_next_id} = 1;
    $self->{_tf} = undef; $self->{_cur_skey} = undef; $self->{_seen_open} = 0;
    $self->{_prev_lmin} = undef;
    $self->{_smc_seen} = 0; $self->{_vp_seen} = 0; $self->{_market_data} = undef;
}

sub update_last {
    my ($self, $md) = @_;
    my $i = $md->last_index; return if $i < 0;
    $self->update_at_index($md, $i);
}

sub _src {
    my ($self, $c) = @_;
    my $s = $self->{src};
    return $c->{close}                                          if $s eq 'close';
    return ($c->{high}+$c->{low})/2                             if $s eq 'hl2';
    return ($c->{open}+$c->{high}+$c->{low}+$c->{close})/4      if $s eq 'ohlc4';
    return ($c->{high}+$c->{low}+$c->{close})/3;                # hlc3 (default)
}

sub _local_min {
    my ($self, $ts) = @_;
    my $loc = $ts + $self->{local_offset_sec};
    $loc %= 86400; $loc += 86400 if $loc < 0;
    return int($loc / 60);
}

sub _session_key {
    my ($self, $md, $ts) = @_;
    return $md->_bucket_ts_for($ts, $self->{session_tf}) if $md->can('_bucket_ts_for');
    return int(($ts + $self->{local_offset_sec} - 17*3600) / 86400);
}

sub update_at_index {
    my ($self, $md, $i) = @_;
    my $c = $md->get_candle($i); return unless defined $c;
    $self->{_market_data} = $md;
    $self->{_tf} = $md->get_timeframe;
    push @{ $self->{_c} }, $c;

    my $src = $self->_src($c);
    my $vol = $c->{volume} // 0;
    my $lm  = $self->_local_min($c->{ts});

    # (1) acumular la vela actual en las anclas YA activas (creadas antes de i).
    for my $a (@{ $self->{_anchors} }) {
        next unless $a->{state} eq 'active';
        $a->{cum_pv} += $src * $vol;   # volumen 0 => suma 0
        $a->{cum_v}  += $vol;
        $a->{value}   = $a->{cum_v} > 0 ? $a->{cum_pv} / $a->{cum_v} : undef;
        $a->{end_ts}  = $c->{ts};
        $a->{end_idx} = $i;            # ultima vela acumulada (congela al pasar a inactive)
    }

    # (2) crear anclas nuevas para esta vela (init con la vela i; sin doble conteo).
    #   -- inicio de sesion (apertura ETH)
    my $skey = $self->_session_key($md, $c->{ts});
    if (!defined $self->{_cur_skey} || $self->{_cur_skey} != $skey) {
        $self->{_cur_skey} = $skey;
        $self->{_seen_open} = 0;   # nueva sesion: re-armar deteccion de apertura oficial
        $self->_new_anchor('session', $i, $src*$vol, $vol, $c->{ts}, $src, { session_key => $skey });
    }
    #   -- apertura oficial del mercado (distinta del inicio ETH): CRUCE hacia
    #      arriba del minuto de apertura (509->510), no un simple ">=". Asi no se
    #      dispara en la apertura ETH (17:00) que ya cumple ">=08:30".
    if (!$self->{_seen_open} && defined $self->{_prev_lmin}
        && $self->{_prev_lmin} < $self->{official_open_min}
        && $lm >= $self->{official_open_min}) {
        $self->{_seen_open} = 1;
        $self->_new_anchor('open', $i, $src*$vol, $vol, $c->{ts}, $src,
                           { open_min => $self->{official_open_min} });
    }
    #   -- BOS / CHoCH confirmados (cursor sobre eventos de SMC; e->ts == ts de i)
    if ($self->{smc}) {
        my $ev = $self->{smc}->get_events;
        while ($self->{_smc_seen} < scalar(@$ev)) {
            my $e = $ev->[ $self->{_smc_seen} ];
            last if $e->{ts} > $c->{ts};                        # sin futuro
            $self->{_smc_seen}++;
            next if defined $self->{anchor_scope} && ($e->{scope}//'') ne $self->{anchor_scope};
            next unless $e->{type} eq 'BOS' || $e->{type} eq 'CHoCH';
            $self->_new_anchor($e->{type}, $i, $src*$vol, $vol, $c->{ts}, $src,
                               { event_ts => $e->{ts}, dir => $e->{dir}, scope => $e->{scope} });
        }
    }
    #   -- POC confirmado: al cerrar un perfil del Volume Profile, anclar en su
    #      vela de control (mayor volumen del perfil), acumulando hacia adelante.
    if ($self->{vp}) {
        my $profs = $self->{vp}->{_profiles};   # perfiles CERRADOS (confirmados)
        while ($self->{_vp_seen} < scalar(@$profs)) {
            my $p = $profs->[ $self->{_vp_seen} ];
            $self->{_vp_seen}++;
            next if $p->{incomplete} || !$p->{_idxs} || !@{ $p->{_idxs} };
            my $pi = $self->_poc_control_index($p);
            next unless defined $pi && $pi <= $i;
            my ($pv, $v) = (0, 0);
            for my $j ($pi .. $i) {
                my $cj = $self->{_c}[$j]; next unless $cj;
                my $vv = $cj->{volume} // 0;
                $pv += $self->_src($cj) * $vv; $v += $vv;
            }
            $self->_new_anchor('POC', $pi, $pv, $v, $self->{_c}[$pi]{ts}, $self->_src($self->{_c}[$pi]),
                               { profile_id => $p->{id}, poc_price => $p->{poc_price} });
        }
    }

    $self->{_prev_lmin} = $lm;
}

# vela de control del perfil = la de mayor volumen (proxy del nodo POC).
sub _poc_control_index {
    my ($self, $p) = @_;
    my ($bk, $bv) = (undef, -1);
    my $cands = $p->{_candles}; my $idxs = $p->{_idxs};
    return undef unless $cands && $idxs;
    for my $k (0 .. $#$cands) {
        my $vv = $cands->[$k]{volume} // 0;
        if ($vv > $bv) { $bv = $vv; $bk = $k; }
    }
    return defined $bk ? $idxs->[$bk] : undef;
}

# vwap_line: serie {idx,value} del VWAP de un ancla en [i_from,i_to] (recortada a
# [start_idx, ultima procesada]). La FORMULA vive aqui (no en el overlay): el
# render solo pide el tramo visible. El ultimo valor coincide con anchor->{value}.
sub vwap_line {
    my ($self, $a, $i_from, $i_to) = @_;
    my $s    = $a->{start_idx};
    my $last = $#{ $self->{_c} };
    # una ancla inactive quedo CONGELADA en su end_idx: la serie no la sobrepasa.
    my $cap  = defined $a->{end_idx} ? $a->{end_idx} : $last;
    $cap = $last if $cap > $last;
    $i_from = $s   if $i_from < $s;
    $i_to   = $cap if $i_to   > $cap;
    return [] if $i_to < $i_from || !defined $s;
    my ($pv, $v) = (0, 0);
    for my $j ($s .. $i_from - 1) {
        my $c = $self->{_c}[$j] or next; my $vv = $c->{volume} // 0;
        $pv += $self->_src($c) * $vv; $v += $vv;
    }
    my @out;
    for my $j ($i_from .. $i_to) {
        my $c = $self->{_c}[$j] or next; my $vv = $c->{volume} // 0;
        $pv += $self->_src($c) * $vv; $v += $vv;
        push @out, { idx => $j, value => ($v > 0 ? $pv / $v : undef) };
    }
    return \@out;
}

sub _new_anchor {
    my ($self, $type, $i, $cum_pv, $cum_v, $ts, $anchor_price, $origin) = @_;
    # sin duplicar: si ya existe un ancla de este tipo con el mismo ts, no crear.
    for my $a (@{ $self->{_anchors} }) {
        return if $a->{type} eq $type && $a->{ts} == $ts;
    }
    # una activa por tipo: la anterior del mismo tipo se congela (inactive).
    for my $a (@{ $self->{_anchors} }) {
        $a->{state} = 'inactive' if $a->{state} eq 'active' && $a->{type} eq $type;
    }
    my $a = {
        id => $self->{_next_id}++, type => $type, ts => $ts, tf => $self->{_tf},
        anchor_price => $anchor_price, cum_pv => $cum_pv, cum_v => $cum_v,
        value => ($cum_v > 0 ? $cum_pv / $cum_v : undef),
        state => 'active', origin => $origin, start_idx => $i, end_idx => $i, end_ts => $ts,
    };
    push @{ $self->{_anchors} }, $a;

    # cap de anclas INACTIVAS (las activas nunca se descartan)
    my @inact = grep { $_->{state} eq 'inactive' } @{ $self->{_anchors} };
    if (@inact > $self->{max_inactive}) {
        my %drop = map { $_->{id} => 1 } @inact[0 .. (@inact - $self->{max_inactive} - 1)];
        @{ $self->{_anchors} } = grep { !$drop{$_->{id}} } @{ $self->{_anchors} };
    }
    return $a;
}

1;
