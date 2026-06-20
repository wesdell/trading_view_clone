package Market::MarketData;

# =============================================================================
# Market::MarketData
# Responsabilidad: almacenar y gestionar datos de mercado OHLCV.
# Garantiza sincronizacion temporal, acceso eficiente por indice
# y construccion de temporalidades (1m -> 5m -> 15m).
# =============================================================================

use strict;
use warnings;
use Time::Moment;

my @DAY_NAMES = qw(Mon Tue Wed Thu Fri Sat Sun);

# -----------------------------------------------------------------------------
# new
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

sub get_data {
    my ($self) = @_;
    return $self->{data};
}

sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}{'1m'} }, $candle;
}

# -----------------------------------------------------------------------------
# build_tf_candles
# FIX: Agrupacion anclada al reloj (Clock-Aligned Grouping).
# Se utiliza el timestamp (Epoch) para forzar que las velas de 5m/15m
# nazcan en multiplos exactos del reloj (ej. 23:20, 23:25), resolviendo
# desfases y huecos de mercado (missing candles).
# -----------------------------------------------------------------------------
sub build_tf_candles {
    my ($self, $tf) = @_;
    my %minutes = ('5m' => 5, '15m' => 15);
    my $n = $minutes{$tf} or return;
    my $interval_sec = $n * 60;
    my $src = $self->{data}{'1m'};
    my @result;
    my $current_candle = undef;

    for my $c (@$src) {
        my $bucket_ts = int($c->{ts} / $interval_sec) * $interval_sec;

        if (!defined $current_candle || $current_candle->{ts} != $bucket_ts) {
            push @result, $current_candle if defined $current_candle;

            $current_candle = {
                time   => $c->{time},  # FIX: heredar time de la 1ra vela 1m del bucket
                ts     => $bucket_ts,
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume},
            };
        } else {
            $current_candle->{high}   = $c->{high}   if $c->{high}  > $current_candle->{high};
            $current_candle->{low}    = $c->{low}    if $c->{low}   < $current_candle->{low};
            $current_candle->{close}  = $c->{close};
            $current_candle->{volume} += $c->{volume};
        }
    }

    push @result, $current_candle if defined $current_candle;
    $self->{data}{$tf} = \@result;
}

sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles('5m');
    $self->build_tf_candles('15m');
}

sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{tf} = $tf if exists $self->{data}{$tf};
}

sub get_timeframe {
    my ($self) = @_;
    return $self->{tf};
}

sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{tf} };
}

sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr  = $self->_active_array;
    my $last = $#$arr;
    $start   = 0     if $start < 0;
    $end     = $last if $end > $last;
    return [] if $start > $end;
    return [ @{$arr}[$start .. $end] ];
}

sub get_candle {
    my ($self, $index) = @_;
    my $arr = $self->_active_array;
    return undef if $index < 0 || $index > $#$arr;
    return $arr->[$index];
}

sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array };
}

sub last_candle {
    my ($self) = @_;
    my $arr = $self->_active_array;
    return undef unless @$arr;
    return $arr->[-1];
}

sub last_index {
    my ($self) = @_;
    return $#{ $self->_active_array };
}

sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return $c ? $c->{ts} : undef;
}

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
            my $dow   = $tm->day_of_week - 1;
            my $label = $DAY_NAMES[$dow] . ' ' . sprintf('%d', $day);
            push @anchors, { index => $i, label => $label, ts => $ts };
            $last_day  = $day;
            $last_hour = $hour;
        } elsif ($hour != $last_hour) {
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