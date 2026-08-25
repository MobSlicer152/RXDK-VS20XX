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
    float mountain = fBM(p * 0.65, 2, 2.0, 0.5);
    float detail = fBM(p * 0.35, 1, 1.5, 0.25);

    return mountain * 3.0 + detail * 0.25 + 0.6;
}

[fastopt]
float TriHeight(float2 p)
{
    float gridSize = 0.5;

    float2 g = p / gridSize;
    float2 cell = floor(g);
    float2 f = frac(g);

    float2 base = cell * gridSize;

    float h00 = RawHeight(base);
    float h10 = RawHeight(base + float2(gridSize, 0.0));
    float h01 = RawHeight(base + float2(0.0, gridSize));

    if (f.x + f.y < 1.0)
    {
        return h00 + f.x * (h10 - h00) + f.y * (h01 - h00);
    }

    float h11 = RawHeight(base + float2(gridSize, gridSize));
    return h11 + (1.0 - f.y) * (h10 - h11) + (1.0 - f.x) * (h01 - h11);
}

float Envelope(float x)
{
    return pow(exp(cos(x - 3.14)), 1.1);
}

float SDF(float3 eye, float3 p)
{
    float mountain = TriHeight(p.xz);
    float zDist = p.z - eye.z;
    float e = Envelope(p.x);
    float height = mountain * e;

    return p.y - height;
}

[fastopt]
float3 CalcNormal(float3 eye, float3 pos)
{
    float e = 0.002;

    float dx = SDF(eye, pos + float3(e, 0, 0)) - SDF(eye, pos - float3(e, 0, 0));
    float dy = SDF(eye, pos + float3(0, e, 0)) - SDF(eye, pos - float3(0, e, 0));
    float dz = SDF(eye, pos + float3(0, 0, e)) - SDF(eye, pos - float3(0, 0, e));

    return normalize(float3(dx, dy, dz));
}

struct Hit
{
    float s;
    float3 p;
   float3 n;
};

#define RAY_STEPS 100
#define MAX_RAY_DIST 64.0
#define MIN_STEP 0.002
#define HIT_EPS 0.02

[fastopt]
bool CastRay(float3 eye, float3 dir, out Hit h)
{
    float total = 0.0;

    for (int i = 0; i < RAY_STEPS; i++)
    {
        float3 p = eye + dir * total;
        float s = SDF(eye, p);

        if (s < HIT_EPS)
        {
            h.s = total;
            h.p = p;
            h.n = CalcNormal(eye, p);
            return true;
        }

        if (total > MAX_RAY_DIST)
        {
            break;
        }

        total += max(s * 0.4, MIN_STEP);
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
