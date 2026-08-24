sampler2D input : register(s0);
float time : register(c0);

float4 main(float2 uv : TEXCOORD) : COLOR
{
    float2 c = uv * 0.5 + 0.5;
    return float4(c.x, 0.0, c.y, 1.0);
}