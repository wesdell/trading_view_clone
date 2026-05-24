package Market::MarketData;

# =============================================================================
# Market::MarketData
# Responsabilidad: almacenar y gestionar datos de mercado OHLCV.
# Garantiza sincronizacion temporal, acceso eficiente por indice
# y construccion de temporalidades (1m -> 5m -> 15m).
#
# Implementacion en Perl puro (Time::Moment es el unico modulo externo),
# segun restricciones del proyecto.
# =============================================================================

use strict;
use warnings;
use Time::Moment;

# Nombres cortos de dias de la semana (estilo TradingView)
my @DAY_NAMES = qw(Mon Tue Wed Thu Fri Sat Sun);

# -----------------------------------------------------------------------------
# new
# Inicializa almacenamiento de datos OHLC.
# $self->{data}: hash keyed por timeframe ('1m', '5m', '15m').
# $self->{tf}  : temporalidad activa.
# -----------------------------------------------------------------------------
sub new {
    my ($class) = @_;
    my $self = {
        data => {
            '1m'  => [],
            '5m'  => [],
            '15m' => [],
        },
        tf => '1m',
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# get_data
# Devuelve la estructura completa de datos (hash de timeframes).
# -----------------------------------------------------------------------------
sub get_data {
    my ($self) = @_;
    return $self->{data};
}

# -----------------------------------------------------------------------------
# add_candle
# Agrega una vela al timeframe '1m'.
# -----------------------------------------------------------------------------
sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}{'1m'} }, $candle;
}

# -----------------------------------------------------------------------------
# build_tf_candles
# Construye velas de una temporalidad a partir de '1m'.
# Agrega N velas de 1m en una sola vela del timeframe destino.
# $tf: '5m' (N=5) o '15m' (N=15)
#
# Reglas de agregacion:
#   open  = primer open
#   high  = max de highs
#   low   = min de lows
#   close = ultimo close
#   vol   = suma de volumenes
# -----------------------------------------------------------------------------
sub build_tf_candles {
    my ($self, $tf) = @_;

    my %minutes = ('5m' => 5, '15m' => 15);
    my $n = $minutes{$tf} or return;

    my $src   = $self->{data}{'1m'};
    my $count = scalar @$src;
    my @result;
    my $i = 0;

    while ($i + $n <= $count) {
        my $first = $src->[$i];
        my $high  = $first->{high};
        my $low   = $first->{low};
        my $vol   = 0;

        # Recorrido sobre las N velas del bloque
        for my $j ($i .. $i + $n - 1) {
            my $c = $src->[$j];
            $high = $c->{high} if $c->{high} > $high;
            $low  = $c->{low}  if $c->{low}  < $low;
            $vol += $c->{volume};
        }

        push @result, {
            time   => $first->{time},
            ts     => $first->{ts},
            open   => $first->{open},
            high   => $high,
            low    => $low,
            close  => $src->[$i + $n - 1]{close},
            volume => $vol,
        };
        $i += $n;
    }

    $self->{data}{$tf} = \@result;
}

# -----------------------------------------------------------------------------
# build_timeframes
# Construye 5m y 15m a partir de 1m.
# -----------------------------------------------------------------------------
sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles('5m');
    $self->build_tf_candles('15m');
}

# -----------------------------------------------------------------------------
# set_timeframe
# Selecciona la temporalidad activa.
# -----------------------------------------------------------------------------
sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{tf} = $tf if exists $self->{data}{$tf};
}

# -----------------------------------------------------------------------------
# get_timeframe
# Devuelve la temporalidad activa.
# -----------------------------------------------------------------------------
sub get_timeframe {
    my ($self) = @_;
    return $self->{tf};
}

# -----------------------------------------------------------------------------
# _active_array  (privado)
# Devuelve el arrayref de candles de la temporalidad activa.
# -----------------------------------------------------------------------------
sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{tf} };
}

# -----------------------------------------------------------------------------
# get_slice
# Devuelve velas [start..end] de la temporalidad activa.
# Indices fuera de rango se recortan.
# -----------------------------------------------------------------------------
sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr  = $self->_active_array;
    my $last = $#$arr;
    $start   = 0     if $start < 0;
    $end     = $last if $end > $last;
    return [] if $start > $end;
    return [ @{$arr}[$start .. $end] ];
}

# -----------------------------------------------------------------------------
# get_candle
# Obtiene una vela por indice.
# -----------------------------------------------------------------------------
sub get_candle {
    my ($self, $index) = @_;
    my $arr = $self->_active_array;
    return undef if $index < 0 || $index > $#$arr;
    return $arr->[$index];
}

# -----------------------------------------------------------------------------
# size
# Numero total de velas en la temporalidad activa.
# -----------------------------------------------------------------------------
sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array };
}

# -----------------------------------------------------------------------------
# last_candle
# Ultima vela de la temporalidad activa.
# -----------------------------------------------------------------------------
sub last_candle {
    my ($self) = @_;
    my $arr = $self->_active_array;
    return undef unless @$arr;
    return $arr->[-1];
}

# -----------------------------------------------------------------------------
# last_index
# Indice de la ultima vela.
# -----------------------------------------------------------------------------
sub last_index {
    my ($self) = @_;
    return $#{ $self->_active_array };
}

# -----------------------------------------------------------------------------
# get_timestamp
# Epoch de una vela por indice.
# -----------------------------------------------------------------------------
sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return $c ? $c->{ts} : undef;
}

# -----------------------------------------------------------------------------
# merge_delta_row
# Actualiza o inserta datos incrementales (streaming).
# Si el ultimo timestamp coincide, actualiza high/low/close/volume.
# Si no, agrega nueva vela.
# -----------------------------------------------------------------------------
sub merge_delta_row {
    my ($self, $row) = @_;
    my $arr = $self->{data}{'1m'};

    if (@$arr && $arr->[-1]{ts} == $row->{ts}) {
        my $e = $arr->[-1];
        $e->{high}   = $row->{high} if $row->{high} > $e->{high};
        $e->{low}    = $row->{low}  if $row->{low}  < $e->{low};
        $e->{close}  = $row->{close};
        $e->{volume} = $e->{volume} + $row->{volume};
    } else {
        $self->add_candle($row);
    }
}

# -----------------------------------------------------------------------------
# compute_time_anchors
# Calcula puntos de ancla para el eje de tiempo (estilo TradingView):
#   - Cambio de dia: "Wed 29", "Thu 30"
#   - Cambio de hora dentro del mismo dia: "03:00", "17:00"
#
# Devuelve arrayref de { index => N, label => 'texto', ts => epoch }
# -----------------------------------------------------------------------------
sub compute_time_anchors {
    my ($self) = @_;
    my $arr      = $self->_active_array;
    my @anchors;
    my $last_day  = -1;
    my $last_hour = -1;

    for my $i (0 .. $#$arr) {
        my $ts  = $arr->[$i]{ts};
        my $tm  = Time::Moment->from_epoch($ts);

        my $day  = $tm->day_of_month;
        my $hour = $tm->hour;
        my $min  = $tm->minute;

        if ($day != $last_day) {
            # Cambio de dia: "Wed 29"
            my $dow   = $tm->day_of_week - 1;  # 0=Mon ... 6=Sun
            my $label = $DAY_NAMES[$dow] . ' ' . sprintf('%d', $day);
            push @anchors, { index => $i, label => $label, ts => $ts };
            $last_day  = $day;
            $last_hour = $hour;
        } elsif ($hour != $last_hour) {
            # Cambio de hora dentro del mismo dia: "HH:MM"
            push @anchors, {
                index => $i,
                label => sprintf('%02d:%02d', $hour, $min),
                ts    => $ts,
            };
            $last_hour = $hour;
        }
    }

    return \@anchors;
}

1;