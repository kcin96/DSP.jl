# Filter types and conversions

abstract Filter

#
# Zero-pole gain form
#

immutable ZPKFilter{Z<:Number,P<:Number,K<:Number} <: Filter
    z::Vector{Z}
    p::Vector{P}
    k::K

    # Remove zeros and poles that cancel
    function ZPKFilter(z::Vector{Z}, p::Vector{P}, k::K)
        (isempty(z) || isempty(p)) && return new(z, p, k)

        # Compute multiplicty of each zero
        zmultiplicity = Dict{Z,Int}()
        for az in z
            zmultiplicity[az] = get(zmultiplicity, az, 0)+1
        end

        # Check for cancelling zeros
        keep = trues(length(p))
        for i = 1:length(p)
            ap = p[i]
            cancelling_zeros = get(zmultiplicity, ap, 0)
            if cancelling_zeros != 0
                zmultiplicity[ap] = cancelling_zeros - 1
                keep[i] = false
            end
        end

        # Build new arrays if necessary
        if all(keep)
            new(z, p, k)
        else
            newz = Z[]
            sizehint(newz, length(z))
            for (az, n) in zmultiplicity
                for i = 1:n
                    push!(newz, az)
                end
            end
            new(newz, p[keep], k)
        end
    end
end
ZPKFilter{Z<:Number,P<:Number,K<:Number}(z::Vector{Z}, p::Vector{P}, k::K) =
    ZPKFilter{Z,P,K}(z,p,k)

#
# Transfer function form
#

immutable TFFilter{T<:Number} <: Filter
    b::Poly{T}
    a::Poly{T}

    TFFilter(b::Poly, a::Poly) =
        new(convert(Poly{T}, b/a[end]), convert(Poly{T}, a/a[end]))
end
TFFilter{T<:Number}(b::Poly{T}, a::Poly{T}) = TFFilter{T}(b, a)

# The DSP convention is highest power first. The Polynomials.jl
# convention is lowest power first.
function TFFilter{T<:Number,S<:Number}(b::Union(T,Vector{T}), a::Union(S,Vector{S}))
    if findfirst(b) == 0 || findfirst(a) == 0
        error("filter must have non-zero numerator and denominator")
    end
    TFFilter{promote_type(T,S)}(Poly(b[end:-1:findfirst(b)]), Poly(a[end:-1:findfirst(a)]))
end

function Base.convert(::Type{TFFilter}, f::ZPKFilter)
    b = f.k*poly(f.z)
    a = poly(f.p)
    TFFilter(Poly(real(b.a)), Poly(real(a.a)))
end

function Base.convert{T}(::Type{ZPKFilter}, f::TFFilter{T})
    k = real(f.b[end])
    b = f.b / k
    z = convert(Vector{Complex{T}}, roots(b))
    p = convert(Vector{Complex{T}}, roots(f.a))
    ZPKFilter(z, p, k)
end

coefb(f::TFFilter) = reverse(f.b.a)
coefa(f::TFFilter) = reverse(f.a.a)

#
# Biquad filter in transfer function form
# A separate immutable to improve efficiency of filtering using SOSFilters
#

immutable BiquadFilter{T} <: Filter
    b0::T
    b1::T
    b2::T
    a1::T
    a2::T
end
BiquadFilter{T}(b0::T, b1::T, b2::T, a0::T, a1::T, a2::T, g::Real=1) =
    BiquadFilter(g*b0/a0, g*b1/a0, g*b2/a0, a1/a0, a2/a0)

Base.convert(::Type{ZPKFilter}, f::BiquadFilter) = convert(ZPKFilter, convert(TFFilter, f))

function Base.convert{T}(::Type{TFFilter}, f::BiquadFilter{T})
    if f.b2 == zero(T) && f.a2 == zero(T)
        if f.b1 == zero(T) && f.a1 == zero(T)
            b = [f.b0]
            a = [one(T)]
        else
            b = [f.b0, f.b1]
            a = [one(T), f.a1]
        end
    else
        b = [f.b0, f.b1, f.b2]
        a = [one(T), f.a1, f.a2]
    end

    TFFilter(b, a)
end

Base.convert(::Type{BiquadFilter}, f::ZPKFilter) = convert(BiquadFilter, convert(TFFilter, f))

function Base.convert{T}(::Type{BiquadFilter}, f::TFFilter{T})
    a, b = f.a, f.b
    xs = max(length(b), length(a))

    if xs == 3
        BiquadFilter(b[2], b[1], b[0], a[1], a[0])
    elseif xs == 2
        BiquadFilter(b[1], b[0], zero(T), a[0], zero(T))
    elseif xs == 1
        BiquadFilter(b[0], zero(T), zero(T), zero(T), zero(T))
    elseif xs == 0
        error("cannot convert an empty TFFilter to BiquadFilter")
    else
        error("cannot convert a filter of length > 3 to BiquadFilter")
    end
end

*(f::BiquadFilter, g::Number) = BiquadFilter(f.b0*g, f.b1*g, f.b2*g, f.a1, f.a2)

#
# Second-order sections (array of biquads)
#

immutable SOSFilter{T,G} <: Filter
    biquads::Vector{BiquadFilter{T}}
    g::G
end

realtype(x::DataType) = x
realtype{T}(::Type{Complex{T}}) = T
complextype(T::DataType) = Complex{T}
complextype{T}(::Type{Complex{T}}) = Complex{T}

function Base.convert{T}(::Type{ZPKFilter}, f::SOSFilter{T})
    t = complextype(T)
    z = t[]
    p = t[]
    k = f.g
    for biquad in f.biquads
        biquadzpk = convert(ZPKFilter, biquad)
        append!(z, biquadzpk.z)
        append!(p, biquadzpk.p)
        k *= biquadzpk.k
    end
    ZPKFilter(z, p, k)
end

Base.convert(to::Union(Type{TFFilter}, Type{BiquadFilter}), f::SOSFilter) =
    convert(to, convert(ZPKFilter, f))

# Convert a filter to second-order sections
# The returned sections are in ZPK form
function Base.convert{Z,P}(::Type{SOSFilter}, f::ZPKFilter{Z,P})
    z = f.z
    p = f.p
    length(z) > length(p) && error("ZPKFilter must not have more zeros than poles")
    n = length(p)

    # Sort poles lexicographically so that matched poles are adjacent
    p = sort(p, order=Base.Order.Lexicographic)

    # Sort poles according to distance to unit circle (farthest first)
    p = sort!(p, by=x->abs(abs(x) - 1), rev=true)

    # Move real poles to the end
    complexp = P[]
    realp = P[]
    for x in p
        push!(ifelse(imag(x) == zero(P), realp, complexp), x)
    end
    append!(complexp, realp)
    p = complexp

    # Group each pole with its closest zero
    zorder = zeros(Int, length(z)) # map from zero indices -> pole indices
    used = fill(false, length(p))  # whether poles have been mapped
    for i = 1:length(z)
        closest_pole_idx = 1
        closest_pole_val = Inf
        for j = 1:length(p)
            !used[j] || continue
            val = abs(z[i] - p[j])
            if val < closest_pole_val
                closest_pole_idx = j
                closest_pole_val = val
            end
        end
        used[closest_pole_idx] = true
        zorder[i] = closest_pole_idx
    end

    # Build second-order sections
    T = promote_type(realtype(Z), realtype(P))
    biquads = Array(BiquadFilter{T}, (n >> 1)+(n & 1))
    for i = 1:div(n, 2)
        biquads[i] = convert(BiquadFilter, ZPKFilter(z[2i-1 .<= zorder .<= 2i], p[2i-1:2i], one(T)))
    end
    if isodd(n)
        biquads[end] = convert(BiquadFilter, ZPKFilter([z[zorder .== length(p)]], [p[end]], one(T)))
    end

    SOSFilter(biquads, f.k)
end

Base.convert(::Type{SOSFilter}, f::Filter) = convert(SOSFilter, convert(ZPKFilter, f))