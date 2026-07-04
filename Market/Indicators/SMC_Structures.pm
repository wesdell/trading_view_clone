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

        _c            => [],
        _fvgs         => [],
        _active_fvgs  => [],
        _events       => [],
        _order_blocks => [],
        _active_obs   => [],

        _struct_swings  => [],
        _last_sh_price  => undef,
        _last_sl_price  => undef,
        _seen_sh_idx    => -1,
        _seen_sl_idx    => -1,
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
    $self->{_last_sh_price}  = undef;
    $self->{_last_sl_price}  = undef;
    $self->{_seen_sh_idx}    = -1;
    $self->{_seen_sl_idx}    = -1;
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
    $self->_detect_fvg($i);
    $self->_update_fvgs($i);
    $self->_update_obs($i);
    $self->_detect_bos_choch($i);
}

# -----------------------------------------------------------------------------
# _update_swing_structure: clasifica nuevos swings como HH/HL/LH/LL
# Compara cada nuevo swing high con el previo (HH si es mayor, LH si menor),
# igual para lows (HL si mayor, LL si menor). Mantiene los 4 niveles
# estructurales vigentes para que _detect_bos_choch use los correctos.
# -----------------------------------------------------------------------------
sub _update_swing_structure {
    my ($self) = @_;
    my $liq = $self->{liquidity};
    return unless $liq;

    my $sh = $liq->last_swing_high;
    if ($sh && $sh->{index} != $self->{_seen_sh_idx}) {
        my $label = (!defined $self->{_last_sh_price})          ? 'HH'
                  : ($sh->{price} > $self->{_last_sh_price})    ? 'HH'
                  :                                                'LH';

        push @{ $self->{_struct_swings} }, {
            index => $sh->{index}, price => $sh->{price},
            kind  => 'H',         label => $label, ts => $sh->{ts},
        };
        if ($label eq 'HH') { $self->{_last_hh} = {index=>$sh->{index}, price=>$sh->{price}}; }
        else                 { $self->{_last_lh} = {index=>$sh->{index}, price=>$sh->{price}}; }

        $self->{_last_sh_price}          = $sh->{price};
        $self->{_seen_sh_idx}            = $sh->{index};
        $self->{_new_sh_since_last_down} = 1;
    }

    my $sl = $liq->last_swing_low;
    if ($sl && $sl->{index} != $self->{_seen_sl_idx}) {
        my $label = (!defined $self->{_last_sl_price})          ? 'LL'
                  : ($sl->{price} < $self->{_last_sl_price})    ? 'LL'
                  :                                                'HL';

        push @{ $self->{_struct_swings} }, {
            index => $sl->{index}, price => $sl->{price},
            kind  => 'L',         label => $label, ts => $sl->{ts},
        };
        if ($label eq 'HL') { $self->{_last_hl} = {index=>$sl->{index}, price=>$sl->{price}}; }
        else                 { $self->{_last_ll} = {index=>$sl->{index}, price=>$sl->{price}}; }

        $self->{_last_sl_price}        = $sl->{price};
        $self->{_seen_sl_idx}          = $sl->{index};
        $self->{_new_sl_since_last_up} = 1;
    }

    @{ $self->{_struct_swings} } = sort { $a->{index} <=> $b->{index} }
                                        @{ $self->{_struct_swings} };
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
        next if $i <= $f->{created};
        if ($f->{dir} eq 'bull' && $cur->{low} <= $f->{bottom})  { $f->{state}='mitigated'; $f->{mitig_at}=$i; next; }
        if ($f->{dir} eq 'bear' && $cur->{high} >= $f->{top})    { $f->{state}='mitigated'; $f->{mitig_at}=$i; next; }
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