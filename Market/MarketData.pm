package Market::MarketData;

# =============================================================================
# Market::MarketData
# Responsabilidad: almacenar y gestionar datos de mercado OHLCV.
# Garantiza sincronizacion temporal, acceso eficiente por indice
# y construccion de temporalidades (1m -> 5m -> 15m -> 1h -> 2h -> 4h -> D -> W).
# =============================================================================

use strict;
use warnings;
use Time::Moment;

my @DAY_NAMES = qw(Mon Tue Wed Thu Fri Sat Sun);

# -----------------------------------------------------------------------------
# Temporalidades derivadas soportadas (todo excepto 1m, que es la base
# alimentada directamente por add_candle).
# -----------------------------------------------------------------------------
my @DERIVED_TIMEFRAMES = qw(5m 15m 1h 2h 4h D W);

# Temporalidades intradia que se agregan por bucketing directo sobre el
# epoch (igual que 5m/15m en Fase 1). Estos intervalos dividen exacto a
# 1440 min/dia, asi que el ancla es estable sin convertir a zona local.
my %TF_MINUTES = (
    '5m'  => 5,
    '15m' => 15,
    '1h'  => 60,
    '2h'  => 120,
    '4h'  => 240,
);

# Ancla horaria para D y W: GMT-5, consistente con el resto del sistema
# (PricePanel/ChartEngine ya usan gmtime($ts+5*3600) para etiquetas de
# dia/fecha). Offset en minutos para Time::Moment->from_epoch.
use constant GMT_OFFSET_MIN => -300;

# -----------------------------------------------------------------------------
# new
# -----------------------------------------------------------------------------
sub new {
    my ($class) = @_;
    my %data = ( '1m' => [] );
    $data{$_} = [] for @DERIVED_TIMEFRAMES;

    my $self = {
        data => \%data,
        tf   => '1m',

        # Frontera de Replay (Etapa 3, Fase 2): undef = modo "en vivo",
        # sin restriccion (comportamiento de Fase 1 intacto). Si tiene
        # un valor, es un timestamp epoch: ningun accesor publico debe
        # exponer velas con ts posterior a este valor.
        replay_boundary_ts => undef,
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
# _bucket_ts_for (privado)
# Calcula el timestamp de "inicio de bucket" para una vela 1m dada,
# segun la temporalidad destino. Centraliza la decision de anclaje:
#   - 5m/15m/1h/2h/4h -> bucketing directo sobre el epoch (UTC).
#   - D               -> medianoche GMT-5.
#   - W               -> 00:00 del lunes en GMT-5.
# -----------------------------------------------------------------------------
sub _bucket_ts_for {
    my ($self, $ts, $tf) = @_;

    if (exists $TF_MINUTES{$tf}) {
        my $interval_sec = $TF_MINUTES{$tf} * 60;
        return int($ts / $interval_sec) * $interval_sec;
    }

    if ($tf eq 'D') {
        my $tm = Time::Moment->from_epoch($ts)->with_offset_same_instant(GMT_OFFSET_MIN);
        return $self->_truncate_to_midnight($tm)->epoch;
    }

    if ($tf eq 'W') {
        my $tm  = Time::Moment->from_epoch($ts)->with_offset_same_instant(GMT_OFFSET_MIN);
        my $dow = $tm->day_of_week;   # 1=Lunes .. 7=Domingo (ISO 8601)
        return $self->_truncate_to_midnight($tm)->minus_days($dow - 1)->epoch;
    }

    return undef;
}

# -----------------------------------------------------------------------------
# _truncate_to_midnight (privado)
# Trunca un Time::Moment a las 00:00:00.000000000 de su mismo dia/offset.
# Existe porque esta version de Time::Moment no expone at_start_of_day.
# -----------------------------------------------------------------------------
sub _truncate_to_midnight {
    my ($self, $tm) = @_;
    return $tm->with_hour(0)->with_minute(0)->with_second(0)->with_nanosecond(0);
}

# -----------------------------------------------------------------------------
# build_tf_candles
# FIX: Agrupacion anclada al reloj (Clock-Aligned Grouping), generalizada
# a las 7 temporalidades derivadas. _bucket_ts_for decide la frontera
# correcta (epoch o calendario GMT-5 segun el caso), resolviendo desfases
# y huecos de mercado (missing candles) igual que en Fase 1.
# -----------------------------------------------------------------------------
sub build_tf_candles {
    my ($self, $tf) = @_;
    return unless exists $TF_MINUTES{$tf} || $tf eq 'D' || $tf eq 'W';

    my $src = $self->{data}{'1m'};
    my @result;
    my $current_candle = undef;

    for my $c (@$src) {
        my $bucket_ts = $self->_bucket_ts_for($c->{ts}, $tf);

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
    $self->build_tf_candles($_) for @DERIVED_TIMEFRAMES;
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

# -----------------------------------------------------------------------------
# _effective_last_index (privado)
# Devuelve el ultimo indice visible del array activo, respetando la
# frontera de Replay si esta activa. Sin frontera, es simplemente
# $#$arr (comportamiento de Fase 1, intacto). Con frontera, es el
# ultimo indice cuyo ts no supera replay_boundary_ts, encontrado por
# busqueda binaria (el array esta siempre ordenado ascendente por ts).
#
# Este es el UNICO punto del sistema donde se decide "hasta donde se
# puede ver". Todos los accesores publicos (size, last_candle,
# last_index, get_candle, get_slice, compute_time_anchors) delegan
# aqui, por lo que automaticamente respetan el replay sin que el
# resto del sistema (IndicatorManager, ChartEngine, Overlays) necesite
# saber que existe.
# -----------------------------------------------------------------------------
sub _effective_last_index {
    my ($self) = @_;
    my $arr = $self->_active_array;
    my $hi  = $#$arr;

    return $hi unless defined $self->{replay_boundary_ts};
    return -1 if $hi < 0;

    my $boundary = $self->{replay_boundary_ts};
    return -1 if $arr->[0]{ts}  > $boundary;   # el replay arranca antes de todos los datos
    return $hi if $arr->[$hi]{ts} <= $boundary; # el replay ya cubre todo el array

    my ($lo, $found) = (0, -1);
    while ($lo <= $hi) {
        my $mid = int( ($lo + $hi) / 2 );
        if ( $arr->[$mid]{ts} <= $boundary ) {
            $found = $mid;
            $lo    = $mid + 1;
        } else {
            $hi = $mid - 1;
        }
    }
    return $found;
}

# -----------------------------------------------------------------------------
# set_replay_boundary / clear_replay_boundary / get_replay_boundary /
# is_replay_active
# Gestion de la frontera de Replay. set_replay_boundary(undef) equivale
# a clear_replay_boundary().
# -----------------------------------------------------------------------------
sub set_replay_boundary {
    my ($self, $ts) = @_;
    $self->{replay_boundary_ts} = $ts;
}

sub clear_replay_boundary {
    my ($self) = @_;
    $self->{replay_boundary_ts} = undef;
}

sub get_replay_boundary {
    my ($self) = @_;
    return $self->{replay_boundary_ts};
}

sub is_replay_active {
    my ($self) = @_;
    return defined $self->{replay_boundary_ts} ? 1 : 0;
}

# -----------------------------------------------------------------------------
# raw_last_index / raw_get_candle / raw_size
# Accesores que IGNORAN la frontera de Replay -- ven el array activo
# completo. Uso EXCLUSIVO de Market::Replay (necesita saber hasta donde
# puede avanzar el puntero y "espiar" la siguiente vela real). Ningun
# otro consumidor del sistema (ChartEngine, IndicatorManager, Overlays)
# debe usar estos metodos.
# -----------------------------------------------------------------------------
sub raw_last_index {
    my ($self) = @_;
    return $#{ $self->_active_array };
}

sub raw_size {
    my ($self) = @_;
    return scalar @{ $self->_active_array };
}

sub raw_get_candle {
    my ($self, $index) = @_;
    my $arr = $self->_active_array;
    return undef if $index < 0 || $index > $#$arr;
    return $arr->[$index];
}

sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr  = $self->_active_array;
    my $last = $self->_effective_last_index;
    $start   = 0     if $start < 0;
    $end     = $last if $end > $last;
    return [] if $last < 0 || $start > $end;
    return [ @{$arr}[$start .. $end] ];
}

sub get_candle {
    my ($self, $index) = @_;
    my $last = $self->_effective_last_index;
    return undef if $index < 0 || $index > $last;
    return $self->_active_array->[$index];
}

sub size {
    my ($self) = @_;
    return $self->_effective_last_index + 1;
}

sub last_candle {
    my ($self) = @_;
    my $idx = $self->_effective_last_index;
    return undef if $idx < 0;
    return $self->_active_array->[$idx];
}

sub last_index {
    my ($self) = @_;
    return $self->_effective_last_index;
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
    my $last     = $self->last_index;   # consciente de la frontera de replay
    my @anchors;
    my $last_day  = -1;
    my $last_hour = -1;

    for my $i (0 .. $last) {
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