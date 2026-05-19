# Market::IndicatorManager
# Responsabilidad: Gestionar multiples indicadores tecnicos de forma
# desacoplada. Permite registrar, actualizar y consultar indicadores
# sin acoplarlos al sistema de render.
# ==============================================================================

package Market::IndicatorManager;

use strict;
use warnings;

# ------------------------------------------------------------------------------
# new
# Inicializa el contenedor de indicadores.
# ------------------------------------------------------------------------------
sub new {
    my ($class) = @_;
    my $self = {
        indicators => {},   # { nombre => objeto_indicador }
        _order     => [],   # orden de registro (para iteracion determinista)
    };
    bless $self, $class;
    return $self;
}

# ------------------------------------------------------------------------------
# register
# Registra un indicador bajo un nombre clave.
# Permite extensibilidad sin modificar esta clase.
# Parametros:
#   $name      : string identificador (ej: 'ATR')
#   $indicator : objeto con interfaz update_last / get_values / reset
# ------------------------------------------------------------------------------
sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
    push @{ $self->{_order} }, $name
        unless grep { $_ eq $name } @{ $self->{_order} };
}

# ------------------------------------------------------------------------------
# update_last
# Actualiza todos los indicadores registrados con la ultima vela del mercado.
# Calculo incremental eficiente: O(1) por indicador despues del warmup.
# Parametro $market_data: objeto Market::MarketData
# ------------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;
    for my $name (@{ $self->{_order} }) {
        $self->{indicators}{$name}->update_last($market_data);
    }
}

# ------------------------------------------------------------------------------
# get
# Obtiene la referencia al array completo de valores de un indicador.
# Parametro $name: string nombre del indicador
# Retorna: arrayref o undef si no existe
# ------------------------------------------------------------------------------
sub get {
    my ($self, $name) = @_;
    return undef unless exists $self->{indicators}{$name};
    return $self->{indicators}{$name}->get_values();
}

# ------------------------------------------------------------------------------
# slice_array
# Devuelve una porcion de los valores de un indicador entre $start y $end.
# Sincroniza con la ventana visible del chart (mismos indices que get_slice).
# Parametros:
#   $name  : string nombre del indicador
#   $start : indice inicial (inclusive)
#   $end   : indice final   (inclusive)
# Retorna: lista de valores (puede contener undef en el warmup)
# ------------------------------------------------------------------------------
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $vals = $self->get($name);
    return () unless defined $vals;

    my $n = scalar @$vals;
    $start = 0      if $start < 0;
    $end   = $n - 1 if $end   >= $n;
    return () if $start > $end;
    return @{$vals}[$start .. $end];
}

# ------------------------------------------------------------------------------
# reset_all
# Reinicia todos los indicadores registrados.
# Util al cambiar de temporalidad, forzando recalculo completo.
# ------------------------------------------------------------------------------
sub reset_all {
    my ($self) = @_;
    for my $name (@{ $self->{_order} }) {
        $self->{indicators}{$name}->reset();
    }
}

1;