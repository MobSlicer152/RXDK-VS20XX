sampler2D input : register(s0);
float time : register(c0);
float aspect : register(c1);

float SmoothMin(float d1, float d2, float k)
{
    float h = exp(-k * d1) + exp(-k * d2);
    return -log(h) / k;
}

float Circle(float2 pos, float2 c, float r)
{
    return length(pos - c) - r;
}

float4 main(float2 uv : TEXCOORD) : COLOR
{
    float2 aspectScale = float2(aspect, 1.0);
    float2 scaledUv = uv * aspectScale;
    float2 ray = (uv * 2.0 - 1.0) * aspectScale;
    if (Circle(ray, 0.0, 0.5) < 0.0)
    {
        return 1.0;
    }
    
    return 0.0; // tex2D(input, uv);
}