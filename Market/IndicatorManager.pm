package Market::IndicatorManager;

# =============================================================================
# Market::IndicatorManager
# Responsabilidad: gestionar indicadores tecnicos desacoplados del render.
# Permite registrar, recalcular y consultar valores de indicadores.
#
# Cada indicador registrado debe implementar:
#   - update_last($market_data)       (streaming)
#   - update_at_index($md, $idx)      (rebuild)
#   - get_values()  -> arrayref
#   - reset()
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class) = @_;
    bless {
        indicators => {},
        _order     => [],   # orden de registro (iteracion determinista)
    }, $class;
}

# -----------------------------------------------------------------------------
# register
# Registra un indicador bajo un nombre clave (ej: 'atr').
# -----------------------------------------------------------------------------
sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
    push @{ $self->{_order} }, $name
        unless grep { $_ eq $name } @{ $self->{_order} };
}

# -----------------------------------------------------------------------------
# update_last
# Notifica a cada indicador que llego una nueva vela (la ultima).
# Uso: streaming en tiempo real.
# -----------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;
    for my $name (@{ $self->{_order} }) {
        $self->{indicators}{$name}->update_last($market_data);
    }
}

# -----------------------------------------------------------------------------
# rebuild_all
# Recalcula todos los indicadores desde cero recorriendo todos los indices.
# Uso: inicializacion del programa o cambio de timeframe.
# -----------------------------------------------------------------------------
sub rebuild_all {
    my ($self, $market_data) = @_;
    my $size = $market_data->size;
    for my $i (0 .. $size - 1) {
        for my $name (@{ $self->{_order} }) {
            my $ind = $self->{indicators}{$name};
            if ($ind->can('update_at_index')) {
                $ind->update_at_index($market_data, $i);
            }
        }
    }
}

# -----------------------------------------------------------------------------
# get
# Devuelve el arrayref de valores de un indicador (paralelo a las velas).
# -----------------------------------------------------------------------------
sub get {
    my ($self, $name) = @_;
    return undef unless exists $self->{indicators}{$name};
    return $self->{indicators}{$name}->get_values;
}

# -----------------------------------------------------------------------------
# slice_array
# Devuelve los valores del indicador para el rango [start..end].
# Los undef se preservan (velas sin valor calculado, p.ej. seed del ATR).
# -----------------------------------------------------------------------------
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $vals = $self->get($name);
    return [] unless defined $vals && @$vals;

    my $last = $#$vals;
    $start = 0     if $start < 0;
    $end   = $last if $end > $last;
    return [] if $start > $end;

    return [ @{$vals}[$start .. $end] ];
}

# -----------------------------------------------------------------------------
# reset_all
# Reinicia todos los indicadores (necesario al cambiar timeframe).
# -----------------------------------------------------------------------------
sub reset_all {
    my ($self) = @_;
    for my $name (@{ $self->{_order} }) {
        $self->{indicators}{$name}->reset;
    }
}

1;