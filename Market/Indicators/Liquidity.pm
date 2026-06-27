package Market::Indicators::Liquidity;

# =============================================================================
# Market::Indicators::Liquidity   (Tabla 1 del PDF)
#
# Motor de deteccion analitica de Swing Points, EQH/EQL, BSL/SSL y de la
# maquina de estados de liquidez (Sweep / Grab / Run). SOLO calcula y
# almacena datos: NUNCA dibuja en el Canvas (eso es Overlays/Liquidity.pm).
#
# Cumple el contrato de IndicatorManager:
#   - update_at_index($md, $idx)   (rebuild secuencial)
#   - update_last($md)             (streaming / avance de replay)
#   - reset()
#   - get_values()                 (vacio: este indicador expone eventos, no
#                                    una serie escalar paralela a las velas)
#
# Garantia anti-futuro: se procesa vela a vela en orden. Un swing en el indice
# j SOLO se confirma cuando ya existen las k velas posteriores (j+k). Por eso,
# durante el Replay (donde MarketData acota el dataset), jamas se confirma una
# estructura usando informacion que el operador "todavia no deberia conocer".
#
# Referencias teoricas: Teoria1.txt (estructura de mercado, BOS/CHoCH) y
# Teoria2.txt (liquidez, sweeps, equal highs/lows), seccion 4 del PDF.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        atr          => $args{atr},                 # objeto indicador ATR (tolerancia EQH/EQL)
        k            => $args{k}          // 3,     # profundidad de swing
        eq_factor    => $args{eq_factor}  // 0.10,  # tolerancia = ATR * 0.10
        accept_n     => $args{accept_n}   // 3,     # velas para Acceptance -> Run
        grab_window  => $args{grab_window} // 3,    # ventana de Grab (rechazo rapido)

        # Cota de niveles "en observacion" simultaneos. La liquidez lejana en
        # el tiempo que el precio nunca volvio a tocar deja de evaluarse (como
        # en TradingView/ICT). Evita el coste cuadratico de revisar miles de
        # niveles DETECTED por vela en temporalidades grandes (1m).
        max_active   => $args{max_active} // 160,

        _c      => [],   # velas procesadas (refs)
        _swings => [],   # { kind=>'H'|'L', index, ts, price }
        _levels => [],   # niveles BSL/SSL (historico completo, para el overlay)
        _active => [],   # subconjunto en observacion (DETECTED|SWEPT)
        _events => [],   # eventos resueltos (Sweep/Grab/Run)
        _eq     => [],   # pares Equal High / Equal Low

        # Buffers O(1): ultimos swings recientes por tipo (para EQH/EQL) y el
        # ultimo swing confirmado de cada tipo (estructura "mayor" para SMC).
        _buf_h    => [],
        _buf_l    => [],
        _recent_h => undef,
        _recent_l => undef,
    };
    bless $self, $class;
    return $self;
}

# Contrato IndicatorManager (no produce serie escalar).
sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_swings} = [];
    $self->{_levels} = [];
    $self->{_active} = [];
    $self->{_events} = [];
    $self->{_eq}     = [];
    $self->{_buf_h}    = [];
    $self->{_buf_l}    = [];
    $self->{_recent_h} = undef;
    $self->{_recent_l} = undef;
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

# -----------------------------------------------------------------------------
# Accesores de solo lectura para el Overlay.
# -----------------------------------------------------------------------------
sub get_swings { return $_[0]->{_swings}; }
sub get_levels { return $_[0]->{_levels}; }
sub get_events { return $_[0]->{_events}; }
sub get_equals { return $_[0]->{_eq}; }

# Ultimo swing confirmado de cada tipo (estructura "mayor" que consume SMC).
sub last_swing_high { return $_[0]->{_recent_h}; }
sub last_swing_low  { return $_[0]->{_recent_l}; }

# -----------------------------------------------------------------------------
# _atr_at: valor de ATR en un indice (para tolerancia EQH/EQL).
# -----------------------------------------------------------------------------
sub _atr_at {
    my ( $self, $i ) = @_;
    return 0 unless $self->{atr};
    my $v = $self->{atr}->get_values;
    return 0 unless $v && @$v;
    my $a = ( $i >= 0 && $i <= $#$v ) ? $v->[$i] : $v->[-1];
    return defined $a ? $a : 0;
}

# -----------------------------------------------------------------------------
# _process: integra una vela nueva en el indice n = $#_c.
# -----------------------------------------------------------------------------
sub _process {
    my ( $self, $c ) = @_;
    push @{ $self->{_c} }, $c;
    my $i = $#{ $self->{_c} };          # indice absoluto de la vela actual
    my $k = $self->{k};

    # 1) Confirmacion de swing en j = i - k (ya existen las k velas a la derecha)
    my $j = $i - $k;
    if ( $j - $k >= 0 ) {
        $self->_confirm_swing($j);
    }

    # 2) Avanzar la maquina de estados de cada nivel no resuelto.
    $self->_advance_levels($i);
}

# -----------------------------------------------------------------------------
# _confirm_swing: aplica la condicion de vecindad simetrica (PDF 4.1).
#   Swing High: High[j] > High[j-k..j-1]  y  High[j] > High[j+1..j+k]
#   Swing Low : Low[j]  < Low[j-k..j-1]   y  Low[j]  < Low[j+1..j+k]
# -----------------------------------------------------------------------------
sub _confirm_swing {
    my ( $self, $j ) = @_;
    my $c   = $self->{_c};
    my $k   = $self->{k};
    my $piv = $c->[$j];

    my $is_high = 1;
    my $is_low  = 1;
    for my $m ( $j - $k .. $j + $k ) {
        next if $m == $j;
        $is_high = 0 if $c->[$m]{high} >= $piv->{high};
        $is_low  = 0 if $c->[$m]{low}  <= $piv->{low};
    }

    if ($is_high) {
        my $sw = { kind => 'H', index => $j, ts => $piv->{ts}, price => $piv->{high} };
        push @{ $self->{_swings} }, $sw;
        $self->{_recent_h} = $sw;
        $self->_register_level( 'buy', $j, $piv->{high}, $piv->{ts} );      # BSL
        $self->_check_equal( $self->{_buf_h}, 'EQH', $sw );                  # EQH
        push @{ $self->{_buf_h} }, $sw;
        shift @{ $self->{_buf_h} } while @{ $self->{_buf_h} } > 6;
    }
    if ($is_low) {
        my $sw = { kind => 'L', index => $j, ts => $piv->{ts}, price => $piv->{low} };
        push @{ $self->{_swings} }, $sw;
        $self->{_recent_l} = $sw;
        $self->_register_level( 'sell', $j, $piv->{low}, $piv->{ts} );      # SSL
        $self->_check_equal( $self->{_buf_l}, 'EQL', $sw );                  # EQL
        push @{ $self->{_buf_l} }, $sw;
        shift @{ $self->{_buf_l} } while @{ $self->{_buf_l} } > 6;
    }
}

# -----------------------------------------------------------------------------
# _register_level: crea un nivel de liquidez en estado DETECTED.
#   side 'buy'  -> BSL (encima de un swing high): ordenes Buy Stop.
#   side 'sell' -> SSL (debajo de un swing low) : ordenes Sell Stop.
# -----------------------------------------------------------------------------
sub _register_level {
    my ( $self, $side, $idx, $price, $ts ) = @_;
    my $lv = {
        side    => $side,
        kind    => ( $side eq 'buy' ? 'BSL' : 'SSL' ),
        index   => $idx,
        ts      => $ts,
        price   => $price,
        state   => 'DETECTED',      # DETECTED -> SWEPT -> RESOLVED
        swept_i => undef,
        out_n   => 0,               # cierres consecutivos fuera del nivel
        result  => undef,           # SWEEP | GRAB | RUN (inmutable al resolver)
    };
    push @{ $self->{_levels} }, $lv;   # historico (overlay)
    push @{ $self->{_active} }, $lv;   # en observacion (maquina de estados)
}

# -----------------------------------------------------------------------------
# _check_equal: detecta EQH/EQL comparando el swing nuevo contra el buffer de
# swings recientes del mismo tipo, con tolerancia dinamica = ATR * eq_factor
# (PDF 4.1). O(1) por swing gracias al buffer acotado.
# -----------------------------------------------------------------------------
sub _check_equal {
    my ( $self, $buf, $eqkind, $sw ) = @_;
    my $tol = $self->_atr_at( $sw->{index} ) * $self->{eq_factor};

    for ( my $p = $#$buf ; $p >= 0 ; $p-- ) {
        my $prev = $buf->[$p];
        if ( abs( $prev->{price} - $sw->{price} ) <= $tol ) {
            push @{ $self->{_eq} }, {
                kind => $eqkind,
                i1   => $prev->{index}, p1 => $prev->{price}, ts1 => $prev->{ts},
                i2   => $sw->{index},   p2 => $sw->{price},   ts2 => $sw->{ts},
            };
            last;
        }
    }
}

# -----------------------------------------------------------------------------
# _advance_levels: maquina de estados de la seccion 4.2-4.3 del PDF.
#   DETECTED -> SWEPT      cuando el precio cruza el extremo del nivel.
#   SWEPT    -> RESOLVED   clasificando en:
#       SWEEP : la vela del barrido cierra de vuelta dentro del rango previo
#               (o reclama dentro tras la ventana de grab).
#       GRAB  : reclamo/rechazo rapido dentro de <= grab_window velas.
#       RUN   : accept_n cierres consecutivos estrictamente fuera del nivel.
# -----------------------------------------------------------------------------
sub _advance_levels {
    my ( $self, $i ) = @_;
    my $cur = $self->{_c}[$i];
    my $gw  = $self->{grab_window};
    my $an  = $self->{accept_n};

    for my $lv ( @{ $self->{_active} } ) {
        next if $lv->{state} eq 'RESOLVED';
        next if $lv->{index} >= $i;     # no evaluar contra su propia vela origen

        my $buy   = ( $lv->{side} eq 'buy' );
        my $price = $lv->{price};

        if ( $lv->{state} eq 'DETECTED' ) {
            my $crossed = $buy ? ( $cur->{high} > $price ) : ( $cur->{low} < $price );
            next unless $crossed;

            $lv->{state}   = 'SWEPT';
            $lv->{swept_i} = $i;

            my $inside = $buy ? ( $cur->{close} < $price ) : ( $cur->{close} > $price );
            if ($inside) {
                $self->_resolve( $lv, 'SWEEP', $i );   # barrido y cierre dentro: Sweep
            } else {
                $lv->{out_n} = 1;                      # cerro fuera: pendiente
            }
            next;
        }

        if ( $lv->{state} eq 'SWEPT' ) {
            my $inside = $buy ? ( $cur->{close} < $price ) : ( $cur->{close} > $price );
            if ($inside) {
                my $span = $i - $lv->{swept_i};
                my $type = ( $span <= $gw ) ? 'GRAB' : 'SWEEP';
                $self->_resolve( $lv, $type, $i );
            } else {
                $lv->{out_n}++;
                $self->_resolve( $lv, 'RUN', $i ) if $lv->{out_n} >= $an;
            }
        }
    }

    # ----- Poda del set en observacion -----
    # 1) sacar los ya resueltos. 2) si excede max_active, descartar los
    # DETECTED mas antiguos (liquidez lejana que el precio nunca revisito);
    # los SWEPT se conservan siempre porque resuelven en pocas velas.
    my @keep = grep { $_->{state} ne 'RESOLVED' } @{ $self->{_active} };
    if ( @keep > $self->{max_active} ) {
        my @swept = grep { $_->{state} eq 'SWEPT' }    @keep;
        my @det   = grep { $_->{state} eq 'DETECTED' } @keep;
        my $room  = $self->{max_active} - scalar @swept;
        $room = 0 if $room < 0;
        @det = ( $room > 0 && @det > $room ) ? @det[ -$room .. -1 ]
             : ( $room > 0 ? @det : () );
        @keep = ( @swept, @det );
    }
    $self->{_active} = \@keep;
}

# -----------------------------------------------------------------------------
# _resolve: archiva la clasificacion final (inmutable) y emite el evento que
# consumira el Overlay.
# -----------------------------------------------------------------------------
sub _resolve {
    my ( $self, $lv, $type, $i ) = @_;
    $lv->{state}  = 'RESOLVED';
    $lv->{result} = $type;

    my $cur  = $self->{_c}[$i];
    my $buy  = ( $lv->{side} eq 'buy' );
    my $label =
        ( $type eq 'SWEEP' ) ? ( $buy ? "SWEEP \x{2191}" : "SWEEP \x{2193}" )
      : ( $type eq 'GRAB' )  ? 'LQ GRAB'
      :                        'LQ RUN';

    push @{ $self->{_events} }, {
        type   => $type,                       # SWEEP | GRAB | RUN
        side   => $lv->{side},                 # buy | sell
        dir    => ( $buy ? 'up' : 'down' ),
        index  => $i,                          # vela donde se resuelve
        ts     => $cur->{ts},
        price  => $lv->{price},
        origin => $lv->{index},                # vela del nivel original
        label  => $label,
        state  => 'RESOLVED',
    };
}

1;
