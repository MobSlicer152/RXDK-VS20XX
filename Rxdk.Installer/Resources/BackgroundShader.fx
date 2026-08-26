sampler input : register(s0);
float time : register(c0);
float aspect : register(c1);

float Circle(float2 pos, float2 c, float r)
{
    return length(pos - c) - r;
}

float2 Hash(float2 p)
{
    const float2 v1 = float2(127.1, 311.7);
    const float2 v2 = float2(269.5, 183.3);
    p = float2(dot(p, v1), dot(p, v2));
    return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
}

float Perlin(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float n00 = dot(Hash(i), f);
    float n10 = dot(Hash(i + float2(1.0, 0.0)), f - float2(1.0, 0.0));
    float n01 = dot(Hash(i + float2(0.0, 1.0)), f - float2(0.0, 1.0));
    float n11 = dot(Hash(i + float2(1.0, 1.0)), f - float2(1.0, 1.0));

    return lerp(lerp(n00, n10, u.x), lerp(n01, n11, u.x), u.y);
}

[fastopt]
float fBM(float2 p, int octaves, float lacunarity, float gain)
{
    float a = 0.5;
    float freq = 1.0;
    float result = 0.0;

    for (int i = 0; i < octaves; i++)
    {
        result += a * Perlin(p * freq);
        freq *= lacunarity;
        a *= gain;
    }

    return result;
}

float RawHeight(float2 p)
{
    // perlin is cheaper and close enough
    float mountain = Perlin(p * 0.65); //fBM(p * 0.65, 2, 2.0, 0.5);
    float detail = Perlin(p * 0.35); //fBM(p * 0.35, 1, 1.5, 0.25);

    return mountain * 3.0 + detail * 0.25 + 0.6;
}

float Envelope(float x)
{
    return pow(exp(cos(x - 3.14)), 1.1);
}

float PointTriangleDistance(float3 p, float3 a, float3 b, float3 c)
{
    float3 ab = b - a;
    float3 ac = c - a;
    float3 ap = p - a;

    float d1 = dot(ab, ap);
    float d2 = dot(ac, ap);

    if (d1 <= 0.0 && d2 <= 0.0)
    {
        return length(ap);
    }

    float3 bp = p - b;

    float d3 = dot(ab, bp);
    float d4 = dot(ac, bp);

    if (d3 >= 0.0 && d4 <= d3)
    {
        return length(bp);
    }

    float vc = d1 * d4 - d3 * d2;

    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0)
    {
        float v = d1 / (d1 - d3);
        float3 q = a + v * ab;
        return length(p - q);
    }

    float3 cp = p - c;

    float d5 = dot(ab, cp);
    float d6 = dot(ac, cp);

    if (d6 >= 0.0 && d5 <= d6)
    {
        return length(cp);
    }

    float vb = d5 * d2 - d1 * d6;

    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0)
    {
        float w = d2 / (d2 - d6);
        float3 q = a + w * ac;
        return length(p - q);
    }

    float va = d3 * d6 - d5 * d4;

    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0)
    {
        float w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        float3 q = b + w * (c - b);
        return length(p - q);
    }

    float3 n = normalize(cross(ab, ac));
    return abs(dot(p - a, n));
}

void GetTriangle(float3 p, out float3 a, out float3 b, out float3 c)
{
    const float gridSize = 0.5;

    float2 g = p.xz / gridSize;
    float2 cell = floor(g);
    float2 f = frac(g);

    float2 base = cell * gridSize;

    float h00 = RawHeight(base);
    float h10 = RawHeight(base + float2(gridSize, 0));
    float h01 = RawHeight(base + float2(0, gridSize));
    float h11 = RawHeight(base + float2(gridSize, gridSize));

    float3 v00 = float3(base.x, h00 * Envelope(base.x), base.y);
    float3 v10 = float3(base.x + gridSize, h10 * Envelope(base.x + gridSize), base.y);
    float3 v01 = float3(base.x, h01 * Envelope(base.x), base.y + gridSize);
    float3 v11 = float3(base.x + gridSize, h11 * Envelope(base.x + gridSize), base.y + gridSize);

    if (f.x + f.y < 1.0)
    {
        a = v00;
        b = v10;
        c = v01;
    }
    else
    {
        a = v10;
        b = v11;
        c = v01;
    }
}

float SDF(float3 eye, float3 p)
{
    float3 a, b, c;
    GetTriangle(p, a, b, c);

    float3 n = normalize(cross(b - a, c - a));
    if (n.y < 0.0)
    {
        n = -n;
    }

    return dot(p - a, n);
}

[fastopt]
float3 CalcNormal(float3 eye, float3 pos)
{
    float3 a, b, c;
    GetTriangle(pos, a, b, c);

    float3 n = normalize(cross(b - a, c - a));
    if (n.y < 0.0)
    {
        n = -n;
    }

    return n;
}

struct Hit
{
    float s;
    float3 p;
    float3 n;
};

#define RAY_STEPS 64
#define MAX_RAY_DIST 32.0
#define MIN_STEP 0.002
#define HIT_EPS 0.005

[fastopt]
bool CastRay(float3 eye, float3 dir, out Hit h)
{
    float total = 0.0;

    float prevS = SDF(eye, eye);

    for (int i = 0; i < RAY_STEPS; i++)
    {
        float3 p = eye + dir * total;
        float s = SDF(eye, p);

        if (abs(s) < HIT_EPS)
        {
            h.s = total;
            h.p = p;
            h.n = CalcNormal(eye, p);
            return true;
        }

        if (prevS > 0.0 && s < 0.0)
        {
            float lo = total - max(prevS, MIN_STEP);
            float hi = total;

            for (int j = 0; j < 8; j++)
            {
                float mid = (lo + hi) * 0.5;

                float3 mp = eye + dir * mid;
                float ms = SDF(eye, mp);

                if (ms > 0.0)
                {
                    lo = mid;
                }
                else
                {
                    hi = mid;
                }
            }

            total = (lo + hi) * 0.5;

            h.s = total;
            h.p = eye + dir * total;
            h.n = CalcNormal(eye, h.p);

            return true;
        }

        prevS = s;

        if (total > MAX_RAY_DIST)
        {
            break;
        }

        total += max(abs(s) * 0.5, MIN_STEP);
    }

    return false;
}


[fastopt]
float TriangleEdge(float2 p)
{
    float gridSize = 0.5;
    float2 f = frac(p / gridSize);

    if (f.x + f.y < 1.0)
    {
        return min(min(f.x, f.y), 1.0 - f.x - f.y);
    }

    return min(min(1.0 - f.x, 1.0 - f.y), f.x + f.y - 1.0);
}

[fastopt]
float4 CalcLight(Hit hit)
{
    float2 p = hit.p.xz;
    
    float edge = TriangleEdge(p);
    float lineWidth = 0.025;
    float grid = 1.0 - smoothstep(0.0, lineWidth, edge);
    float3 lightDir = normalize(float3(-0.5, 1.0, -0.5));
    float diffuse = max(dot(hit.n, lightDir), 0.0);

    float3 darkBlue = float3(0.0, 0.005, 0.035);
    float3 blue = float3(0.0, 0.06, 0.35);
    float3 purple = float3(0.9, 0.0, 0.8);
    float3 brightBlue = float3(0.0, 0.55, 1.0);

    float3 edgeColor = lerp(purple, brightBlue, Envelope(p.x) * 0.5);

    float3 color = lerp(darkBlue, blue, diffuse);
    color = lerp(color, edgeColor, grid);

    return float4(color, 1.0);
}

float4 Render(float2 uv)
{
    float2 aspectScale = float2(aspect, -1.0);
    float2 ray = (uv * 2.0 - 1.0) * aspectScale;

    float shift = time * 10;
    float3 eye = float3(0, 1.5, -5 + shift);

    Hit hit;

    if (CastRay(eye, normalize(float3(ray, 1)), hit))
    {
        return CalcLight(hit);
    }

    float sun = Circle(ray, float2(0.0, 0.3), 0.3);
    if (sun < 0.0)
    {
        float p = (1.0 - uv.y) * 5 - 2;
        return lerp(float4(0.8, 0.9, 0.0, 1.0), float4(1.0, 0.7, 0.0, 1.0), p);
    }

    float gradient = Circle(ray, float2(0.0, 0.5), 0.01);
    float alpha = saturate(gradient + 0.4);

    float3 sky = lerp(float3(0.5, 0.0, 0.6), float3(0.6, 0.6, 0.0), uv.y);

    return float4(sky, alpha);
}

float4 main(float2 uv : TEXCOORD) : COLOR
{
    return Render(uv);
}
