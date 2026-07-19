package Market::Indicators::DailyLevels;

# =============================================================================
# Market::Indicators::DailyLevels
#
# Soporte/Resistencia por "coincidencia mas cercana" (revision del ingeniero,
# entrega 2): se toma el precio de la ULTIMA vela completa de D (y por
# separado de 4H), y se busca hacia atras, entre los 4 valores (O/H/L/C) de
# CADA vela historica anterior de esa misma temporalidad, cual es el precio
# mas CERCANO al precio actual (distancia minima). Ese nivel se marca:
#   - Soporte    si esta POR DEBAJO del precio actual
#   - Resistencia si esta POR ARRIBA del precio actual
#
# Independiente de la temporalidad ACTIVA del grafico: lee directamente los
# arrays 'D' y '4h' de MarketData, para que "Show Daily HL" pueda mostrarse
# en CUALQUIER temporalidad, incluida 1m (pedido explicito de la revision).
#
# GARANTIA DE NO-FUGA DE FUTURO EN REPLAY:
#   Los arrays 'D'/'4h' de MarketData se construyen UNA SOLA VEZ al arrancar
#   la app (build_timeframes), con el dataset COMPLETO -- no respetan la
#   frontera de replay por si mismos (a diferencia del array de la TF activa,
#   que si la respeta via _effective_last_index). Por eso aqui NO basta con
#   filtrar por "ts de inicio de vela <= boundary": una vela cuyo inicio esta
#   dentro del boundary pero cuyo CIERRE DE SESION cae despues ya tiene su
#   O/H/L/C agregados con datos futuros. Se exige que la vela este COMPLETA
#   dentro del boundary (ts_inicio + intervalo <= boundary); si la ultima
#   vela visible esta a medio formar, se descarta y se usa la anterior.
#
# Recalculo perezoso: solo se re-evalua cuando la vela de referencia
# (identificada por su ts) CAMBIA -- evita recorrer el historico de D/4H en
# cada tick de 1m durante un rebuild grande.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        _levels  => {},   # tf => { ref_price, level, kind, ref_ts }
        _last_ts => {},   # tf => ts de la vela de referencia ya procesada
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }
sub get_level  { my ($self, $tf) = @_; return $self->{_levels}{$tf}; }

sub reset {
    my ($self) = @_;
    $self->{_levels}  = {};
    $self->{_last_ts} = {};
}

# update_at_index ignora $idx a proposito -- este indicador no corre sobre
# la TF activa, sino directamente sobre 'D' y '4h' (mismo patron ya usado
# por Indicators::ZigZag, que tambien ignora el indice recibido).
sub update_at_index {
    my ($self, $md, $idx) = @_;
    $self->_recompute($md);
}

sub update_last {
    my ($self, $md) = @_;
    $self->_recompute($md);
}

sub _recompute {
    my ($self, $md) = @_;
    my $boundary = $md->get_replay_boundary;

    for my $tf ('D', '4h') {
        my $arr = $md->get_data->{$tf};
        next unless $arr && @$arr;

        my $interval = $md->tf_interval_seconds($tf);
        my $last_i   = $#$arr;

        if (defined $boundary) {
            while ($last_i >= 0) {
                my $c = $arr->[$last_i];
                if ($c->{ts} > $boundary) { $last_i--; next; }
                if (defined $interval && ($c->{ts} + $interval) > $boundary) {
                    # Vela a medio formar dentro del boundary: su O/H/L/C ya
                    # esta agregado con datos POSTERIORES al boundary (ver
                    # nota de cabecera) -- se descarta, no es una referencia
                    # valida todavia.
                    $last_i--; next;
                }
                last;
            }
        }
        next if $last_i < 1;   # hace falta la vela de referencia + al menos 1 anterior

        my $ref = $arr->[$last_i];
        next if defined($self->{_last_ts}{$tf}) && $self->{_last_ts}{$tf} == $ref->{ts};
        $self->{_last_ts}{$tf} = $ref->{ts};

        my $ref_price = $ref->{close};
        my ($best_diff, $best_price);
        for my $i (0 .. $last_i - 1) {
            my $c = $arr->[$i];
            for my $v ($c->{open}, $c->{high}, $c->{low}, $c->{close}) {
                my $diff = abs($v - $ref_price);
                if (!defined($best_diff) || $diff < $best_diff) {
                    $best_diff  = $diff;
                    $best_price = $v;
                }
            }
        }
        next unless defined $best_price;

        $self->{_levels}{$tf} = {
            ref_price => $ref_price,
            ref_ts    => $ref->{ts},
            level     => $best_price,
            kind      => ($best_price < $ref_price) ? 'support' : 'resistance',
        };
    }
}

1;