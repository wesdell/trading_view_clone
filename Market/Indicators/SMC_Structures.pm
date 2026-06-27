package Market::Indicators::SMC_Structures;

# =============================================================================
# Market::Indicators::SMC_Structures   (Tabla 1 del PDF)
#
# Calculo algoritmico de BOS, CHoCH y FVG, con integracion nativa con los
# vectores de liquidez (lee los Swing Points ya confirmados por
# Indicators/Liquidity.pm para resolver la estructura de mercado).
# SOLO calcula: el dibujo es de Overlays/SMC_Structures.pm.
#
# Anti-futuro: procesa vela a vela. El FVG se confirma al cerrar la 3a vela
# del patron; la mitigacion y el desvanecimiento dependen unicamente de las
# velas ya disponibles (el "avance real" del replay), nunca de velas futuras.
#
# Para esta entrega (29/06) SMC se entrega como "avances": FVG completo +
# BOS/CHoCH basicos. Fibonacci se reserva para la 2a presentacion.
#
# Referencias: Teoria1.txt (BOS valido = cierre de cuerpo mas alla del nivel;
# CHoCH = ruptura de la ultima estructura mayor opuesta), seccion 4-5 del PDF.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        liquidity => $args{liquidity},        # indicador de liquidez (swings)
        max_age   => $args{max_age} // 50,    # velas hasta expiracion visual del FVG

        _c       => [],    # velas procesadas
        _fvgs    => [],    # zonas FVG (historico completo, para el overlay)
        _active_fvgs => [],# FVG activos (aun no mitigados/expirados) a evaluar
        _events  => [],    # eventos BOS / CHoCH

        _bias   => undef,  # 'bull' | 'bear'
        _bh_idx => -1,     # indice del ultimo swing high ya roto (anti-duplicado)
        _bl_idx => -1,     # indice del ultimo swing low  ya roto
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_fvgs}   = [];
    $self->{_active_fvgs} = [];
    $self->{_events} = [];
    $self->{_bias}   = undef;
    $self->{_bh_idx} = -1;
    $self->{_bl_idx} = -1;
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_process($c);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $c = $md->last_candle;
    return unless defined $c;
    $self->_process($c);
}

# Accesores de solo lectura para el Overlay.
sub get_fvgs       { return $_[0]->{_fvgs}; }
sub get_events     { return $_[0]->{_events}; }
sub processed_last { return $#{ $_[0]->{_c} }; }   # ultima vela conocida (replay-aware)

# -----------------------------------------------------------------------------
# _process: integra la vela en el indice i = $#_c.
# -----------------------------------------------------------------------------
sub _process {
    my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };

    $self->_detect_fvg($i);
    $self->_update_fvgs($i);
    $self->_detect_bos_choch($i);
}

# -----------------------------------------------------------------------------
# _detect_fvg: patron de 3 velas (i-2, i-1, i), confirmado al cerrar la vela i.
#   Alcista: Low[i]  > High[i-2]  -> hueco entre High[i-2] (piso) y Low[i] (techo)
#   Bajista: High[i] < Low[i-2]   -> hueco entre High[i] (piso) y Low[i-2] (techo)
# -----------------------------------------------------------------------------
sub _detect_fvg {
    my ( $self, $i ) = @_;
    return if $i < 2;
    my $c  = $self->{_c};
    my $a  = $c->[ $i - 2 ];
    my $z  = $c->[$i];

    my $fvg;
    if ( $z->{low} > $a->{high} ) {
        $fvg = $self->_make_fvg( 'bull', $i, $a->{high}, $z->{low} );
    }
    elsif ( $z->{high} < $a->{low} ) {
        $fvg = $self->_make_fvg( 'bear', $i, $z->{high}, $a->{low} );
    }
    if ($fvg) {
        push @{ $self->{_fvgs} }, $fvg;          # historico (overlay)
        push @{ $self->{_active_fvgs} }, $fvg;   # a evaluar (mitigacion/edad)
    }
}

sub _make_fvg {
    my ( $self, $dir, $i, $bottom, $top ) = @_;
    my $c = $self->{_c};
    return {
        dir       => $dir,                 # 'bull' | 'bear'
        idx_start => $i - 2,               # 1a vela del patron
        ts_start  => $c->[ $i - 2 ]{ts},
        idx_create => $i,                  # vela de confirmacion (3a)
        ts_create => $c->[$i]{ts},
        created   => $i,
        bottom    => $bottom,              # precio inferior de la zona
        top       => $top,                 # precio superior de la zona
        state     => 'active',             # active | mitigated | expired
        mitig_at  => undef,
    };
}

# -----------------------------------------------------------------------------
# _update_fvgs: actualiza mitigacion y expiracion usando SOLO la vela actual.
#   Alcista mitigado : Low[i]  <= bottom  (el precio rellena el hueco)
#   Bajista mitigado : High[i] >= top
#   Expirado         : edad (i - created) > max_age  (deja de dibujarse pero
#                      NO se borra: se conserva para la fase 2).
# -----------------------------------------------------------------------------
sub _update_fvgs {
    my ( $self, $i ) = @_;
    my $cur = $self->{_c}[$i];
    my @keep;
    for my $f ( @{ $self->{_active_fvgs} } ) {
        if ( $i <= $f->{created} ) { push @keep, $f; next; }

        if ( $f->{dir} eq 'bull' && $cur->{low} <= $f->{bottom} ) {
            $f->{state} = 'mitigated'; $f->{mitig_at} = $i; next;   # sale del set
        }
        if ( $f->{dir} eq 'bear' && $cur->{high} >= $f->{top} ) {
            $f->{state} = 'mitigated'; $f->{mitig_at} = $i; next;
        }
        if ( ( $i - $f->{created} ) > $self->{max_age} ) {
            $f->{state} = 'expired'; next;                          # sale del set
        }
        push @keep, $f;
    }
    $self->{_active_fvgs} = \@keep;
}

# -----------------------------------------------------------------------------
# _detect_bos_choch: usa los swings ya confirmados por Liquidity.
#   BOS  = ruptura (cierre de cuerpo) del ultimo swing en la MISMA direccion
#          de la tendencia (continuacion).
#   CHoCH= ruptura del ultimo swing OPUESTO (cambio de caracter / reversion).
# Validez: se exige cierre del cuerpo mas alla del nivel (no solo mecha).
# -----------------------------------------------------------------------------
sub _detect_bos_choch {
    my ( $self, $i ) = @_;
    my $liq = $self->{liquidity};
    return unless $liq;

    my $cur = $self->{_c}[$i];

    # Estructura "mayor": ultimo swing high/low confirmado. El indicador de
    # liquidez los mantiene en O(1); por la confirmacion retrasada (k velas)
    # su indice siempre es < i, por lo que nunca se usa informacion futura.
    my $mh = $liq->last_swing_high;
    my $ml = $liq->last_swing_low;

    # Ruptura alcista: cierre por encima del swing high mayor aun no roto.
    if ( $mh && $mh->{index} != $self->{_bh_idx} && $cur->{close} > $mh->{price} ) {
        my $type = ( defined $self->{_bias} && $self->{_bias} eq 'bear' )
            ? 'CHoCH' : 'BOS';
        $self->_emit( $type, 'up', $i, $mh->{price}, $mh->{index} );
        $self->{_bias}   = 'bull';
        $self->{_bh_idx} = $mh->{index};
    }

    # Ruptura bajista: cierre por debajo del swing low mayor aun no roto.
    if ( $ml && $ml->{index} != $self->{_bl_idx} && $cur->{close} < $ml->{price} ) {
        my $type = ( defined $self->{_bias} && $self->{_bias} eq 'bull' )
            ? 'CHoCH' : 'BOS';
        $self->_emit( $type, 'down', $i, $ml->{price}, $ml->{index} );
        $self->{_bias}   = 'bear';
        $self->{_bl_idx} = $ml->{index};
    }
}

sub _emit {
    my ( $self, $type, $dir, $i, $price, $origin ) = @_;
    push @{ $self->{_events} }, {
        type      => $type,        # BOS | CHoCH
        dir       => $dir,         # up | down
        index     => $i,           # vela de ruptura (cierre mas alla del nivel)
        origin    => $origin,      # indice del swing roto (inicio de la linea)
        ts        => $self->{_c}[$i]{ts},
        price     => $price,
        label     => $type,
        confirmed => 1,
    };
}

1;
