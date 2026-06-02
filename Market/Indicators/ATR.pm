package Market::Indicators::ATR;

# =============================================================================
# Market::Indicators::ATR
# Average True Range (Wilder)
#
# Modificado para rellenar el inicio:
# Las primeras (period-1) velas calculan un promedio progresivo (SMA)
# para que la linea nazca exactamente en la vela 0 sin dejar huecos.
# A partir de la vela `period`, se aplica el suavizado original de Wilder.
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
        _seeded     => 0,        # 1 cuando ya se calculo el seed completo
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
# Calcula el TR de la vela y actualiza el ATR.
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
    my $count = scalar @{ $self->{_trs} };

    if (!$self->{_seeded}) {
        # Promedio Simple Progresivo para rellenar los primeros espacios
        my $sum = 0;
        $sum += $_ for @{ $self->{_trs} };
        my $current_atr = $sum / $count;

        $self->{_last_atr} = $current_atr;
        push @{ $self->{values} }, $current_atr;

        # Cuando llegamos a la cantidad del periodo (ej. 14), activamos el suavizado de Wilder
        if ($count >= $n) {
            $self->{_seeded} = 1;
        }
    } else {
        # Suavizado de Wilder original
        my $new_atr = ($self->{_last_atr} * ($n - 1) + $tr) / $n;
        $self->{_last_atr} = $new_atr;
        push @{ $self->{values} }, $new_atr;
    }
}

# -----------------------------------------------------------------------------
# get_values
# Devuelve arrayref completo de valores ATR.
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