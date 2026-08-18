//-----------------------------------------------------------------------------
// File: XActBasicSound.cpp
//
// Desc: This sample demonstrates the basic functionality of XACT by showing
//       how to create and play sounds using the XACT runtime engine.

// Hist: 7.11.02 - New for August 2002 XDK
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//-----------------------------------------------------------------------------
#include <xbapp.h>
#include <xact.h>
#include <dsstdfx.h>


//-----------------------------------------------------------------------------
// This sample has no graphics framework, so nothing it does is visible on
// screen: a failure returns straight to the loader and looks exactly like a
// silent success. Every step reports itself to the debug channel instead.
//-----------------------------------------------------------------------------
#define TRACE(s)           OUTPUT_DEBUG_STRING( "XActBasicSound: " s "\n" )
#define TRACE_FAIL(s, hr)  DbgPrint( "XActBasicSound: " s " failed, hr=0x%08x\n", (hr) )




//-----------------------------------------------------------------------------
// Name: main()
// Desc: Entry point to the program.
//-----------------------------------------------------------------------------
HRESULT __cdecl main()
{
    OutputDebugStringA( "SAMPLE: XActBasicSound: main\n" );

    HRESULT                 hr                  = S_OK;         // Return code
    IXACTEngine*            pXACT               = NULL;         // XACT Engine instance
    IXACTWaveBank*          pStreamingWaveBank  = NULL;         // XACT Wave Bank
    IXACTSoundBank*         pSoundBank          = NULL;         // XACT Sound Bank
    IXACTSoundSource*       pSoundSource        = NULL;         // XACT Sound Source

    // Set full 3D sound processing
    DirectSoundUseFullHRTF();

    // Initialize the XACT runtime parameters
    XACT_RUNTIME_PARAMETERS xrParams = {0};
    xrParams.dwMax2DHwVoices         = 128; // Maximum number of 2D hardware voices/streams XACT engine will use
    xrParams.dwMax3DHwVoices         = 32;  // Maximum number of 3D hardware voices/streams XACT engine will use, between 0 and 64
    xrParams.dwMaxConcurrentStreams  = 16;  // Maximum number of 2D voices XACT may use for streaming from the hard drive/DVD
    xrParams.dwMaxNotifications      = 0;   // Maximum number of notifications, 0 = default

    TRACE( "starting" );

    // Create the XACT runtime engine
    if( FAILED( hr = XACTEngineCreate( &xrParams, &pXACT ) ) )
    {
        TRACE_FAIL( "XACTEngineCreate", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at XACTEngineCreate - exiting\n" );
        return hr;
    }

    TRACE( "XACT engine created" );

    // Open the streaming wave bank file
    HANDLE hStreamingWaveBank = CreateFile( "D:\\media\\sounds\\XactSounds_streaming.xwb",
                                            GENERIC_READ, FILE_SHARE_READ, NULL,
                                            OPEN_EXISTING, FILE_FLAG_OVERLAPPED | FILE_FLAG_NO_BUFFERING, NULL );
    if( INVALID_HANDLE_VALUE == hStreamingWaveBank )
    {
        DbgPrint( "XActBasicSound: cannot open XactSounds_streaming.xwb, error %d\n", GetLastError() );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at CreateFile - exiting\n" );
        return XBAPPERR_MEDIANOTFOUND;
    }

    // Initialize the streaming wave bank parameters
    XACT_WAVEBANK_STREAMING_PARAMETERS wbParams = {0};
    wbParams.hFile                        = hStreamingWaveBank;
    wbParams.dwOffset                     = 0;
    wbParams.dwPacketSizeInMilliSecs      = 400;
    wbParams.dwPrimePacketSizeInMilliSecs = 400;

    // Register the streaming wave bank with XACT
    if( FAILED( hr = pXACT->RegisterStreamedWaveBank( &wbParams, &pStreamingWaveBank ) ) )
    {
        TRACE_FAIL( "RegisterStreamedWaveBank", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at RegisterStreamedWaveBank - exiting\n" );
        return hr;
    }

    TRACE( "streaming wave bank registered" );

    // Load the sound bank
    BYTE* pbSoundBank = NULL;
    DWORD dwFileSize  = 0;
    if( FAILED( hr = XBUtil_LoadFile( "D:\\media\\sounds\\XactSounds.xsb", (VOID **)&pbSoundBank, &dwFileSize ) ) )
    {
        TRACE_FAIL( "loading XactSounds.xsb", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at XBUtil_LoadFile - exiting\n" );
        return hr;
    }

    DbgPrint( "XActBasicSound: sound bank loaded, %d bytes\n", dwFileSize );

    // Register the sound bank with XACT
    if( FAILED( hr = pXACT->CreateSoundBank( pbSoundBank, dwFileSize, &pSoundBank ) ) )
    {
        TRACE_FAIL( "CreateSoundBank", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at CreateSoundBank - exiting\n" );
        return hr;
    }

    TRACE( "sound bank created" );

    // Download the standard DirectSound effects image
    DSEFFECTIMAGELOC EffectLoc;
    EffectLoc.dwI3DL2ReverbIndex = GraphI3DL2_I3DL2Reverb;
    EffectLoc.dwCrosstalkIndex   = GraphXTalk_XTalk;
    if( FAILED( hr = XAudioDownloadEffectsImage( "d:\\media\\dsstdfx.bin", 
                                                 &EffectLoc, 
                                                 XAUDIO_DOWNLOADFX_EXTERNFILE, 
                                                 NULL ) ) )
    {
        TRACE_FAIL( "XAudioDownloadEffectsImage", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at XAudioDownloadEffectsImage - exiting\n" );
        return E_FAIL;
    }

    TRACE( "effects image downloaded" );

    // Create a 3D sound source to play our cues on
    if( FAILED( hr = pXACT->CreateSoundSource( XACT_FLAG_SOUNDSOURCE_3D, &pSoundSource ) ) )
    {
        TRACE_FAIL( "CreateSoundSource", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at CreateSoundSource - exiting\n" );
        return hr;
    }

    TRACE( "3D sound source created" );

    // Get the sound cue index from the sound bank
    DWORD dwSoundCueIndex = 0;
    if( FAILED( hr = pSoundBank->GetSoundCueIndexFromFriendlyName( "MusicMono",             // Null-terminated string representing the friendly
                                                                   &dwSoundCueIndex ) ) )   // Pointer to the returned SoundCue index for friendly name
    {
        TRACE_FAIL( "GetSoundCueIndexFromFriendlyName(\"MusicMono\")", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at GetSoundCueIndexFromFriendlyName - exiting\n" );
        return hr;
    }

    DbgPrint( "XActBasicSound: cue \"MusicMono\" is index %d\n", dwSoundCueIndex );

    // Initialize XACT notification struct
    XACT_NOTIFICATION_DESCRIPTION xactNotificationDesc = {0};
    xactNotificationDesc.wType              = eXACTNotification_Stop;
    xactNotificationDesc.wFlags             = XACT_FLAG_NOTIFICATION_USE_SOUNDCUE_INDEX;
    xactNotificationDesc.u.pSoundBank       = pSoundBank;
    xactNotificationDesc.dwSoundCueIndex    = dwSoundCueIndex;
    xactNotificationDesc.hEvent             = NULL;

    // Register a stop notification with the XACT engine.
    // This will allow us to monitor when the cue stops playing.
    if( FAILED( hr = pXACT->RegisterNotification( &xactNotificationDesc ) ) )
    {
        TRACE_FAIL( "RegisterNotification", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at RegisterNotification - exiting\n" );
        return hr;
    }

    // Play the sound cue
    if( FAILED( hr = pSoundBank->Play( dwSoundCueIndex, pSoundSource, XACT_FLAG_SOUNDCUE_AUTORELEASE, NULL) ) )
    {
        TRACE_FAIL( "Play", hr );
        OutputDebugStringA( "SAMPLE: XActBasicSound: FAILED at Play - exiting\n" );
        return hr;
    }

    TRACE( "playing, waiting for the stop notification" );

    // Loop while sound cue is playing
    XACT_NOTIFICATION xactNotification = {0};
    while( pXACT->GetNotification( &xactNotificationDesc, &xactNotification ) != S_OK )
    {
        // Tell the XACT engine to do it's work
        XACTEngineDoWork();
    }

    TRACE( "cue stopped" );
    
    // NULL XACT resource pointers
    pStreamingWaveBank = NULL;

    // Free allocated memory
    SAFE_DELETE_ARRAY( pbSoundBank );

    // Release interfaces
    SAFE_RELEASE( pSoundSource );
    SAFE_RELEASE( pSoundBank );
    SAFE_RELEASE( pXACT );

    TRACE( "done, rebooting" );

    OutputDebugStringA( "SAMPLE: XActBasicSound: exit\n" );

    // Reboot the Xbox console
    XLaunchNewImage( NULL, NULL );

    return S_OK;
}
