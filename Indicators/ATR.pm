# ==============================================================================
# Market::Indicators::ATR
# Responsabilidad: Calcular el Average True Range (ATR) de Wilder.
#
# Algoritmo:
#   True Range (TR) = max(High-Low, |High-PrevClose|, |Low-PrevClose|)
#   Primera ATR     = SMA de los primeros $period valores de TR
#   ATR[i]          = (ATR[i-1] * ($period-1) + TR[i]) / $period   (Wilder)
#
# Validacion: resultado debe coincidir con ATR(14) de TradingView.
# ==============================================================================

package Market::Indicators::ATR;

use strict;
use warnings;

# ------------------------------------------------------------------------------
# new
# Inicializa el indicador ATR con su periodo.
# Parametro $period: entero, por defecto 14 (estandar TradingView / Wilder)
# ------------------------------------------------------------------------------
sub new {
    my ($class, $period) = @_;
    $period //= 14;
    my $self = {
        period      => $period,
        values      => [],       # serie completa de valores ATR calculados
        _tr_buffer  => [],       # buffer de True Range para la fase de warmup
        _prev_close => undef,    # close de la vela anterior
        _warmed_up  => 0,        # 1 cuando ya pasamos la fase SMA inicial
    };
    bless $self, $class;
    return $self;
}

# ------------------------------------------------------------------------------
# update_last
# Actualiza el ATR con la informacion de la ultima vela disponible.
# Disenado para llamarse incrementalmente: cada vez que se agrega una
# vela nueva a market_data, se llama este metodo para mantener la serie
# ATR sincronizada con los datos.
#
# Implementa calculo incremental O(1) despues del warmup inicial.
# Parametro $market_data: objeto Market::MarketData
# ------------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;

    my $last = $market_data->last_candle();
    return unless defined $last;

    my $high  = $last->{high};
    my $low   = $last->{low};
    my $close = $last->{close};

    # True Range requiere el close anterior
    my $tr;
    if (!defined $self->{_prev_close}) {
        # Primera vela: TR = High - Low (no hay cierre previo)
        $tr = $high - $low;
    }
    else {
        my $pc = $self->{_prev_close};
        my $hl = $high - $low;
        my $hc = abs($high - $pc);
        my $lc = abs($low  - $pc);
        $tr = $hl;
        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;
    }

    $self->{_prev_close} = $close;
    my $p = $self->{period};

    if (!$self->{_warmed_up}) {
        # --- Fase warmup: acumular los primeros $period valores de TR ---
        push @{ $self->{_tr_buffer} }, $tr;

        if (scalar @{ $self->{_tr_buffer} } == $p) {
            # Calcular la primera ATR como SMA de los TR acumulados
            my $sum = 0;
            $sum += $_ for @{ $self->{_tr_buffer} };
            my $atr = $sum / $p;

            # Rellenar undef para las velas del warmup (sin ATR valido aun)
            push @{ $self->{values} }, undef for (1 .. $p - 1);
            push @{ $self->{values} }, $atr;
            $self->{_warmed_up} = 1;
            $self->{_last_atr}  = $atr;
        }
        # Si aun no tenemos $period valores, no empujamos nada al array
    }
    else {
        # --- Fase incremental: Wilder smoothing ---
        my $prev_atr = $self->{_last_atr};
        my $atr      = ($prev_atr * ($p - 1) + $tr) / $p;
        push @{ $self->{values} }, $atr;
        $self->{_last_atr} = $atr;
    }
}

# ------------------------------------------------------------------------------
# get_values
# Devuelve la referencia al array completo de valores ATR.
# Los primeros ($period - 1) elementos son undef (sin dato suficiente).
# El array tiene la misma longitud que el numero de velas procesadas.
# Retorna: arrayref
# ------------------------------------------------------------------------------
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# ------------------------------------------------------------------------------
# reset
# Reinicia completamente el indicador (limpia todos los valores y estado).
# Llamar antes de recalcular desde cero al cambiar de temporalidad.
# ------------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{values}      = [];
    $self->{_tr_buffer}  = [];
    $self->{_prev_close} = undef;
    $self->{_warmed_up}  = 0;
    delete $self->{_last_atr};
}

1;