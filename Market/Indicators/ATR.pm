package Market::Indicators::ATR;

# =============================================================================
# Market::Indicators::ATR
# Average True Range (Wilder) - mismo metodo que TradingView.
#
# True Range:
#   TR = max( H-L,  |H - Close_prev|,  |L - Close_prev| )
#
# Suavizado de Wilder:
#   ATR seed  = SMA de los primeros `period` TRs
#   ATR(t)    = ( ATR(t-1) * (period-1) + TR(t) ) / period
#
# Las primeras (period-1) velas tienen ATR = undef (no calculado todavia).
# =============================================================================

use strict;
use warnings;

# -----------------------------------------------------------------------------
# new
# $period: periodo del ATR (default 14)
# -----------------------------------------------------------------------------
sub new {
    my ($class, $period) = @_;
    $period //= 14;
    my $self = {
        period      => $period,
        values      => [],       # ATR calculado por vela (paralelo a candles)
        _trs        => [],       # True Ranges acumulados (fase seed)
        _seeded     => 0,        # 1 cuando ya se calculo el seed
        _last_atr   => undef,    # ATR de la vela anterior (para Wilder)
        _prev_close => undef,    # close de la vela anterior (para TR)
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# update_last
# Procesa la ULTIMA vela del market_data (recien agregada). Uso: streaming.
# -----------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;
    my $last = $market_data->last_candle;
    return unless defined $last;
    $self->_process_candle($last);
}

# -----------------------------------------------------------------------------
# update_at_index
# Procesa la vela en $idx. Uso: rebuild completo (cambio de timeframe).
# -----------------------------------------------------------------------------
sub update_at_index {
    my ($self, $market_data, $idx) = @_;
    my $candle = $market_data->get_candle($idx);
    return unless defined $candle;
    $self->_process_candle($candle);
}

# -----------------------------------------------------------------------------
# _process_candle  (privado)
# Calcula el TR de la vela y actualiza el ATR aplicando seed o Wilder.
# -----------------------------------------------------------------------------
sub _process_candle {
    my ($self, $c) = @_;

    my $high  = $c->{high};
    my $low   = $c->{low};
    my $close = $c->{close};

    # True Range
    my $tr;
    if (defined $self->{_prev_close}) {
        my $cp = $self->{_prev_close};
        my $a  = $high - $low;
        my $b  = abs($high - $cp);
        my $d  = abs($low  - $cp);
        $tr = $a;
        $tr = $b if $b > $tr;
        $tr = $d if $d > $tr;
    } else {
        $tr = $high - $low;
    }
    $self->{_prev_close} = $close;

    push @{ $self->{_trs} }, $tr;
    my $n = $self->{period};

    if (!$self->{_seeded}) {
        if (scalar @{ $self->{_trs} } >= $n) {
            # Seed = SMA de los primeros `period` TRs
            my $sum = 0;
            $sum += $_ for @{ $self->{_trs} };
            my $seed_atr = $sum / $n;

            $self->{_last_atr} = $seed_atr;
            $self->{_seeded}   = 1;

            # Rellenar undef para las velas anteriores al seed
            my $total = scalar @{ $self->{_trs} };
            while (scalar @{ $self->{values} } < $total - 1) {
                push @{ $self->{values} }, undef;
            }
            push @{ $self->{values} }, $seed_atr;
        } else {
            push @{ $self->{values} }, undef;
        }
    } else {
        # Suavizado de Wilder
        my $new_atr = ($self->{_last_atr} * ($n - 1) + $tr) / $n;
        $self->{_last_atr} = $new_atr;
        push @{ $self->{values} }, $new_atr;
    }
}

# -----------------------------------------------------------------------------
# get_values
# Devuelve arrayref completo de valores ATR (con undef en las primeras velas).
# -----------------------------------------------------------------------------
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# -----------------------------------------------------------------------------
# reset
# Reinicia el indicador (necesario al cambiar de timeframe).
# -----------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{values}      = [];
    $self->{_trs}        = [];
    $self->{_seeded}     = 0;
    $self->{_last_atr}   = undef;
    $self->{_prev_close} = undef;
}

1;