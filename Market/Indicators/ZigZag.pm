package Market::Indicators::ZigZag;

# =============================================================================
# Market::Indicators::ZigZag  — v5 (algoritmo correcto)
#
# ZIGZAG INTERNO — replica exacta del ZZMTF (Pine Script v4, LonesomeTheBlue)
#
#   CLAVE: el script de Pine corre sobre las velas del GRAFICO (bar_index
#   se refiere a esas velas), no sobre 1 minuto fijo. El input "ZigZag
#   Resolution" (tf) solo define cada cuanto se reinicia la ventana:
#
#     newbar = inicio de una vela de tf (30m)
#     bi     = valuewhen(newbar, bar_index, prd - 1)
#     len    = bar_index - bi + 1
#
#   Si el grafico esta en una TF MAS FINA que tf (ej: grafico 1m, tf=30m),
#   newbar ocurre cada ~30 velas y len crece dentro del tramo (30 a 60
#   velas). Pero si el grafico esta en una TF IGUAL O MAS GRANDE que tf
#   (ej: grafico en 1h, tf=30m -- este es el caso real del usuario), toda
#   vela del grafico es ya una "nueva vela de 30m" por si sola, entonces
#   newbar es SIEMPRE true y len se vuelve CONSTANTE = prd (2 velas del
#   grafico activo). Por eso replicamos esto corriendo sobre la TF ACTIVA
#   (igual que el externo), no sobre 1 minuto fijo — así el resultado
#   depende de la temporalidad que el usuario esta viendo, igual que en
#   TradingView.
#
#     ph = highestbars(high, len) == 0  => el high actual es maximo de la ventana
#     pl = lowestbars(low,  len) == 0   => el low  actual es minimo de la ventana
#
#   dir solo cambia cuando aparece ph U pl de forma EXCLUSIVA (no ambos a
#   la vez); si dir cambia, se agrega un pivote NUEVO con el valor de ESTA
#   vela; si dir no cambia, se extiende ("el mas extremo gana") el pivote
#   ya agregado en el tramo actual. No hay estado "pendiente" del lado
#   contrario que pueda arrastrarse entre tramos.
#
# ZIGZAG EXTERNO — replica ZigZag Volume Profile [ChartPrime] (Length=150)
#
#   Corre sobre la TF ACTIVA con ventana de 150 velas de esa TF:
#     swingHigh = ta.highest(high, 150)  en la TF activa
#     swingLow  = ta.lowest(low,  150)
#     isBullish = true  cuando high == swingHigh (este bar ES el maximo)
#     isBullish = false cuando low  == swingLow  (este bar ES el minimo)
#     Pivote H confirmado cuando isBullish cambia de true -> false
#     Pivote L confirmado cuando isBullish cambia de false -> true
#
# MULTI-TEMPORALIDAD
#   Cada pivote almacena ts. El overlay convierte ts -> indice activo
#   en render-time via busqueda binaria. Funciona en todas las TFs.
# =============================================================================

use strict;
use warnings;
use Time::Moment;

# INTERNO: ventana en velas de 1m = int_period * minutos_tf
# Con int_period=2 y tf=30m: 2*30=60 velas de 1m
use constant INT_PERIOD  => 2;
use constant INT_TF_MINS => 30;    # minutos del tf del ZZMTF
use constant EXT_LENGTH  => 150;   # ventana del ZigZag Volume Profile

# Minutos equivalentes de cada opcion de "Resolucion" del zigzag interno
# (dropdown en market.pl). 1440 = 1D y 10080 = 1S (semana) son casos
# especiales de calendario, ver _bucket_ts.
our %RESOLUTION_MINUTES = (
    '1m' => 1,     '2m' => 2,     '3m' => 3,     '5m' => 5,
    '10m' => 10,   '15m' => 15,   '30m' => 30,   '45m' => 45,
    '1h' => 60,    '2h' => 120,   '3h' => 180,   '4h' => 240,
    '1D' => 1440,  '1S' => 10080,
);

sub new {
    my ( $class, %args ) = @_;

    my $int_period  = $args{int_period}  // INT_PERIOD;
    my $int_tf_mins = $args{int_tf_mins} // INT_TF_MINS;

    my $self = {
        int_period  => $int_period,
        int_tf_mins => $int_tf_mins,
        ext_length  => $args{ext_length} // EXT_LENGTH,

        _int_segments => [],
        _ext_segments => [],

        # Estado interno (sobre la TF activa)
        _int_last_idx    => -1,    # ultimo indice de la TF activa procesado
        _int_dir         => 0,     # 0=sin definir aun, 1=alcista, -1=bajista
        _int_newbar_idx  => [],    # ultimos 'int_period' indices de la TF
                                   # activa donde empezo una vela de
                                   # int_tf_mins (bi = el mas viejo de esta lista)
        _int_last_bucket => undef,

        # Estado externo (sobre TF activa)
        _ext_last_vis  => -1,
        _ext_isBullish => undef,
        _ext_h_idx     => undef,
        _ext_h_price   => undef,
        _ext_l_idx     => undef,
        _ext_l_price   => undef,

        _market_data => undef,
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# set_int_resolution: cambia la resolucion del zigzag interno en caliente
# (dropdown de market.pl). NO recalcula por si solo: el llamador debe hacer
# reset() + rebuild (ver IndicatorManager::rebuild_one) para reconstruir
# los segmentos con la nueva ventana.
# -----------------------------------------------------------------------------
sub set_int_resolution {
    my ($self, $tf_mins) = @_;
    $self->{int_tf_mins} = $tf_mins;
}

sub get_int_resolution { return $_[0]->{int_tf_mins}; }

sub get_values      { return []; }
sub get_market_data { return $_[0]->{_market_data}; }
sub get_segments    {
    my ($self, $w) = @_;
    return $w eq 'external' ? $self->{_ext_segments} : $self->{_int_segments};
}

# -----------------------------------------------------------------------------
# get_pending_external: punto del pivote externo que aun NO se confirmo
# (equivalente al set_xy2 de Pine: la pierna "en formacion" que se sigue
# repintando hasta que ocurre el proximo flip de isBullish). Devuelve
# undef si todavia no hay suficiente estado para determinarlo.
# -----------------------------------------------------------------------------
sub get_pending_external {
    my ($self) = @_;
    return undef unless defined $self->{_ext_isBullish};

    my $md = $self->{_market_data} or return undef;
    my $arr = $md->get_data->{ $md->get_timeframe } or return undef;

    if ($self->{_ext_isBullish}) {
        return undef unless defined $self->{_ext_h_idx};
        return {
            kind  => 'H',
            ts    => $arr->[ $self->{_ext_h_idx} ]{ts},
            price => $self->{_ext_h_price},
        };
    }
    else {
        return undef unless defined $self->{_ext_l_idx};
        return {
            kind  => 'L',
            ts    => $arr->[ $self->{_ext_l_idx} ]{ts},
            price => $self->{_ext_l_price},
        };
    }
}

sub reset {
    my ($self) = @_;
    $self->{_int_segments}   = [];
    $self->{_ext_segments}   = [];
    $self->{_int_last_idx}   = -1;
    $self->{_int_dir}        = 0;
    $self->{_int_newbar_idx} = [];
    $self->{_int_last_bucket}= undef;
    $self->{_ext_last_vis} = -1;
    $self->{_ext_isBullish}= undef;
    $self->{_ext_h_idx}    = undef;
    $self->{_ext_h_price}  = undef;
    $self->{_ext_l_idx}    = undef;
    $self->{_ext_l_price}  = undef;
    $self->{_market_data}  = undef;
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $md->last_index;
    return if $idx < 0;
    $self->update_at_index( $md, $idx );
}

sub update_at_index {
    my ( $self, $md, $i_active ) = @_;
    $self->{_market_data} = $md;

    # Interno y externo corren sobre la TF ACTIVA (la que el usuario esta
    # viendo). El interno se reinicia via reset()+rebuild_all() cada vez
    # que cambia la temporalidad (ChartEngine::set_timeframe), igual que
    # el externo, para que la ventana se recalcule desde cero.
    my $active_arr = $md->get_data->{ $md->get_timeframe };
    my $last_vis   = $md->last_index;
    return unless $active_arr && @$active_arr && $last_vis >= 0;

    $self->_update_internal($active_arr, $last_vis);
    $self->_update_external($active_arr, $last_vis);
}

# Ancla horaria (GMT-5) usada para alinear los buckets de int_tf_mins,
# igual que Market::MarketData::_bucket_ts_for para timeframes intradia.
use constant INT_LOCAL_OFFSET_SEC => 5 * 3600;
use constant SESSION_OPEN_SEC     => 17 * 3600;   # apertura de sesion CME, 17:00 local
use constant SESSION_OPEN_MIN     => 17 * 60;
use constant GMT_OFFSET_MIN       => -300;        # GMT-5 para Time::Moment

# -----------------------------------------------------------------------------
# _bucket_ts: timestamp de inicio del bucket de resolucion $tf_mins (minutos)
# al que pertenece $ts.
#
#   - tf_mins < 1440 (intradia): bucketing directo sobre el epoch, anclado a
#     la apertura de sesion (17:00 local), igual que Market::MarketData
#     ::_bucket_ts_for. Todas las opciones del dropdown (1..240 min) dividen
#     exacto a 1440, asi que el ancla es estable.
#   - tf_mins == 1440 (1D) o 10080 (1S/semana): NO se puede resolver con
#     division entera de segundos -- una semana no es un multiplo de 7 dias
#     alineado al epoch Unix (1-ene-1970 fue jueves), y el "dia de trading"
#     CME va 17:00->16:00 del dia siguiente, etiquetado por fecha de CIERRE.
#     Se replica la misma logica de calendario que
#     Market::MarketData::_bucket_ts_for para D/W.
# -----------------------------------------------------------------------------
sub _bucket_ts {
    my ($self, $ts, $tf_mins) = @_;

    if ($tf_mins < 1440) {
        my $interval_sec = $tf_mins * 60;
        my $shifted = $ts - INT_LOCAL_OFFSET_SEC - SESSION_OPEN_SEC;
        return int( $shifted / $interval_sec ) * $interval_sec
             + SESSION_OPEN_SEC + INT_LOCAL_OFFSET_SEC;
    }

    my $tm    = Time::Moment->from_epoch($ts)->with_offset_same_instant(GMT_OFFSET_MIN);
    my $mins  = $tm->hour * 60 + $tm->minute;
    my $close = ($mins >= SESSION_OPEN_MIN) ? $tm->plus_days(1) : $tm;

    if ($tf_mins == 1440) {
        return $self->_truncate_to_midnight($close)->epoch;
    }

    # 1S (semana): etiquetada por el lunes de la semana de cierre.
    my $dow = $close->day_of_week;   # 1=Lunes .. 7=Domingo (ISO 8601)
    return $self->_truncate_to_midnight($close)->minus_days($dow - 1)->epoch;
}

sub _truncate_to_midnight {
    my ($self, $tm) = @_;
    return $tm->with_hour(0)->with_minute(0)->with_second(0)->with_nanosecond(0);
}

# =============================================================================
# INTERNO: replica ZZMTF (Pine v4) sobre velas de 1m con ventana dinamica
# que crece dentro de cada tramo de int_tf_mins y se reinicia en cada
# frontera (equivalente a valuewhen(newbar, bar_index, prd-1)).
# =============================================================================
sub _update_internal {
    my ($self, $data, $last_vis) = @_;

    my $prd     = $self->{int_period};
    my $tf_mins = $self->{int_tf_mins};
    my $segs    = $self->{_int_segments};
    my $newbars = $self->{_int_newbar_idx};

    my $start = $self->{_int_last_idx} + 1;

    for my $i ($start .. $last_vis) {
        my $c = $data->[$i] or next;
        $self->{_int_last_idx} = $i;

        # newbar: primera vela 1m de un nuevo tramo de int_tf_mins.
        my $bucket = $self->_bucket_ts( $c->{ts}, $tf_mins );
        if ( !defined $self->{_int_last_bucket} || $bucket != $self->{_int_last_bucket} ) {
            push @$newbars, $i;
            shift @$newbars while @$newbars > $prd;
        }
        $self->{_int_last_bucket} = $bucket;

        # Necesitamos 'prd' fronteras de tf vistas para poder fijar bi
        # (equivalente al na de valuewhen antes de acumular suficiente historia).
        next unless @$newbars >= $prd;

        my $bi  = $newbars->[0];
        my $len = $i - $bi + 1;

        # highestbars(high, len) == 0 / lowestbars(low, len) == 0
        my $is_ph = 1;
        my $is_pl = 1;
        my $win_start = $i - $len + 1;
        $win_start = 0 if $win_start < 0;

        for my $j ($win_start .. $i - 1) {
            $is_ph = 0 if $data->[$j]{high} >= $c->{high};
            $is_pl = 0 if $data->[$j]{low}  <= $c->{low};
            last if !$is_ph && !$is_pl;
        }

        next unless $is_ph || $is_pl;

        # dir solo cambia si ph o pl aparecen de forma EXCLUSIVA; si ambos
        # aparecen a la vez, dir se queda igual (replica exacta del Pine).
        my $dir_prev = $self->{_int_dir};
        my $dir      = $dir_prev;
        if    ($is_ph && !$is_pl) { $dir = 1;  }
        elsif ($is_pl && !$is_ph) { $dir = -1; }
        $self->{_int_dir} = $dir;

        my $kind  = ($dir == 1) ? 'H' : 'L';
        my $value = ($dir == 1) ? $c->{high} : $c->{low};

        if (!@$segs || $dir != $dir_prev) {
            # Pivote nuevo: se siembra con el valor de ESTA vela, sin
            # arrastrar ningun estado "pendiente" del tramo anterior.
            push @$segs, { kind => $kind, ts => $c->{ts}, price => $value };
        }
        else {
            # "El mas extremo gana": extiende el pivote actual del tramo
            # en curso si aparece un extremo mas lejano.
            my $top = $segs->[-1];
            if ( ($dir == 1 && $value > $top->{price})
              || ($dir == -1 && $value < $top->{price}) ) {
                $top->{ts}    = $c->{ts};
                $top->{price} = $value;
            }
        }
    }
}

# =============================================================================
# EXTERNO: replica EXACTA de "ZigZag Volume Profile [ChartPrime]" (Pine v6).
# Traduccion linea por linea del script real (visto en swingLength=150):
#
#   swingHigh = ta.highest(high, swingLength)     -- ventana rodante, incluye la vela actual
#   swingLow  = ta.lowest(low,  swingLength)
#
#   if swingHigh == high: isBullish := true
#   if swingLow  == low:  isBullish := false
#
#   if high[1] == swingHigh[1] and high < swingHigh:
#       barIndexHigh := bar_index[1]
#       priceHigh    := low[1]      # OJO: el script usa el LOW de la vela
#                                   # pico, no su high -- se replica tal cual
#                                   # para calzar pixel a pixel con TradingView
#   if low[1] == swingLow[1] and low > swingLow:
#       barIndexLow := bar_index[1]
#       priceLow    := low[1]
#
#   isBullish[1]->true  confirma el tramo alcista (pivote L en barIndexLow/priceLow)
#   isBullish[1]->false confirma el tramo bajista  (pivote H en barIndexHigh/priceHigh)
#
# priceHigh/priceLow se van "extendiendo" (repintando) en cada vela donde el
# bloque de arriba dispara de nuevo, mientras no ocurra el flip opuesto --
# aqui equivale simplemente a leer el valor mas reciente de _ext_h_price /
# _ext_l_price en el momento del flip, sin necesidad de un paso "extend"
# aparte.
# =============================================================================
sub _update_external {
    my ($self, $arr, $last_vis) = @_;

    my $len  = $self->{ext_length};
    my $segs = $self->{_ext_segments};

    my $start = $self->{_ext_last_vis} + 1;
    $start = $len if $start < $len;   # hace falta 'len' velas + 1 vela [1] previa

    for my $i ($start .. $last_vis) {
        my $c = $arr->[$i] or next;
        $self->{_ext_last_vis} = $i;
        next if $i - 1 < 0;

        my ($sh, $sl)   = $self->_ext_window($arr, $i,   $len);
        my ($sh1, $sl1) = $self->_ext_window($arr, $i-1, $len);

        my $prev_bullish = $self->{_ext_isBullish};
        my $cur_bullish  = $prev_bullish;
        $cur_bullish = 1 if $sh == $c->{high};
        $cur_bullish = 0 if $sl == $c->{low};
        $self->{_ext_isBullish} = $cur_bullish;

        my $prevc = $arr->[$i-1];
        if ($prevc->{high} == $sh1 && $c->{high} < $sh) {
            $self->{_ext_h_idx}   = $i - 1;
            $self->{_ext_h_price} = $prevc->{low};   # replica exacta del Pine
        }
        if ($prevc->{low} == $sl1 && $c->{low} > $sl) {
            $self->{_ext_l_idx}   = $i - 1;
            $self->{_ext_l_price} = $prevc->{low};
        }

        next unless defined $prev_bullish && $cur_bullish != $prev_bullish;

        if ($cur_bullish && defined $self->{_ext_l_idx}) {
            # isBullish false->true: confirma el pivote L recien cerrado
            push @$segs, {
                kind  => 'L',
                ts    => $arr->[ $self->{_ext_l_idx} ]{ts},
                price => $self->{_ext_l_price},
            };
        }
        elsif (!$cur_bullish && defined $self->{_ext_h_idx}) {
            # isBullish true->false: confirma el pivote H recien cerrado
            push @$segs, {
                kind  => 'H',
                ts    => $arr->[ $self->{_ext_h_idx} ]{ts},
                price => $self->{_ext_h_price},
            };
        }
    }
}

# -----------------------------------------------------------------------------
# _ext_window: (swingHigh, swingLow) = ta.highest/ta.lowest(len) terminando
# en el indice $i (ventana [i-len+1 .. i], incluye $i).
# -----------------------------------------------------------------------------
sub _ext_window {
    my ($self, $arr, $i, $len) = @_;
    my $ws = $i - $len + 1;
    $ws = 0 if $ws < 0;
    my ($sh, $sl) = ($arr->[$ws]{high}, $arr->[$ws]{low});
    for my $j ($ws .. $i) {
        $sh = $arr->[$j]{high} if $arr->[$j]{high} > $sh;
        $sl = $arr->[$j]{low}  if $arr->[$j]{low}  < $sl;
    }
    return ($sh, $sl);
}

1;