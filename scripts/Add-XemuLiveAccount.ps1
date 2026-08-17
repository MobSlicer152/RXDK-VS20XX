<#
.SYNOPSIS
Writes Xbox Live user accounts into the config sectors of the xemu HDD image.

.DESCRIPTION
Most of the Live samples check XOnlineGetUsers before they draw anything, and hand off to the
dashboard's account-signup screen when the console has no account. That is the correct offline
behaviour, but it means those samples can never be swept: they never reach their own render loop.
Creating an account for real needs the Live account service, which no longer exists, so the
accounts are planted here instead.

An account is a 120-byte XC_ONLINE_USER_ACCOUNT_STRUCT living in a config sector, four to a
sector, starting at config sector 2. Nothing about it is console-specific: the record is validated
by an HMAC-SHA1 over the struct keyed with a constant that ships in the SDK ("Mar/2002 SDK"), so a
valid record can be built on the host. The credential key inside would normally be encrypted with
the console's hard-disk key; it is left zeroed because it is only consumed during logon, which
cannot succeed offline anyway. So a seeded account gets a sample past the account gate and no
further - the logon then fails the way it would with the network unplugged.

Config sectors live at a fixed offset from the start of the disk (partition0 is the whole drive),
each wrapped in a signature/version/checksum envelope that the console validates before looking at
the payload.

The emulator must not be running: it opens the image with locked=on, and it would not see the new
sector anyway.

.PARAMETER Gamertag
Accounts to write, in order, from slot 0. Several samples (SimpleFriends, SimpleMessaging,
SimpleTeams) want two accounts before they will start.

.PARAMETER Clear
Erase the account sector instead of writing to it, restoring the no-account state.

.EXAMPLE
Add-XemuLiveAccount.ps1
.EXAMPLE
Add-XemuLiveAccount.ps1 -Gamertag RXDKOne, RXDKTwo, RXDKThree
.EXAMPLE
Add-XemuLiveAccount.ps1 -Clear
#>
[CmdletBinding()]
param(
    [string]   $Image = 'D:\Git\xemu-devkit\roms\Original Xbox HDD Image.bin',
    [string[]] $Gamertag = @('RXDKOne', 'RXDKTwo'),
    [switch]   $Clear
)

$ErrorActionPreference = 'Stop'

# xconfig.h: the config sectors sit at sector 8 of the drive, 512 bytes each, and the user
# accounts start at config sector 2 (0 is the network config, 1 the machine account).
$SECTOR_SIZE           = 512
$CONFIG_SECTOR_INDEX   = 8
$USER_ACCOUNT_SECTOR   = 2
$BEGIN_SIGNATURE       = 0x79132568
$END_SIGNATURE         = 0xAA550000L   # exceeds Int32, so keep it wide or the cast below fails
$CONFIG_VERSION        = 1
$CONFIG_SECTOR_COUNT   = 1
$DATA_OFFSET           = 12
$DATA_SIZE             = 492

# xonlinep.h: account record layout and the per-sector capacity.
$ACCOUNT_SIZE          = 120
$ACCOUNTS_PER_SECTOR   = 4
$SIGNATURE_OFFSET      = 112   # the HMAC covers everything before its own 8 bytes
$SIGNATURE_SIZE        = 8

# xonp.h: the signature key, and the epoch/granularity of dwSignatureTime.
$SIGNATURE_KEY         = 'Mar/2002 SDK'
$BASE_SIGNATURE_TIME   = 0x01BF5C72FEFB6A60L
$SIGNATURE_TIME_INCREMENT = 20000000L

if (Get-Process xemu -ErrorAction SilentlyContinue) {
    throw 'xemu is running - close it first (it holds the HDD image open with locked=on)'
}
if ($Gamertag.Count -gt $ACCOUNTS_PER_SECTOR) {
    throw "at most $ACCOUNTS_PER_SECTOR accounts fit in one config sector"
}

# 32-bit one's complement sum, as XConfigChecksum computes it: wrapping 32-bit adds with the
# carries counted separately, then folded back in.
function Get-ConfigChecksum([byte[]] $sector) {
    [uint32] $sum = 0
    [uint32] $carries = 0
    for ($i = 0; $i -lt $sector.Length; $i += 4) {
        $t = [uint64] $sum + [uint64] [BitConverter]::ToUInt32($sector, $i)
        if ($t -gt 0xFFFFFFFFL) { $carries++ }
        $sum = [uint32] ($t -band 0xFFFFFFFFL)
    }
    $t = [uint64] $sum + [uint64] $carries
    if ($t -gt 0xFFFFFFFFL) { $t = ($t -band 0xFFFFFFFFL) + 1 }
    return [uint32] $t
}

function Set-Ascii([byte[]] $buffer, [int] $offset, [int] $size, [string] $text) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($text)
    if ($bytes.Length -ge $size) { throw "'$text' does not fit in $size bytes (needs a NUL)" }
    [Array]::Copy($bytes, 0, $buffer, $offset, $bytes.Length)
}

$offset = ($CONFIG_SECTOR_INDEX + $USER_ACCOUNT_SECTOR) * $SECTOR_SIZE
$stream = [IO.File]::Open($Image, 'Open', 'ReadWrite', 'None')
try {
    $sector = [byte[]]::new($SECTOR_SIZE)

    if ($Clear) {
        # An erased sector fails the envelope check, which is how a virgin console reads.
        for ($i = 0; $i -lt $SECTOR_SIZE; $i++) { $sector[$i] = 0xFF }
        $stream.Position = $offset
        $stream.Write($sector, 0, $SECTOR_SIZE)
        "cleared the account sector at 0x{0:X} - the console now has no accounts" -f $offset
        return
    }

    # dwSignatureTime is a 2-second tick count since January 2000, and orders accounts by age.
    $now  = [DateTime]::UtcNow.ToFileTimeUtc()
    $tick = [uint32] (($now - $BASE_SIGNATURE_TIME) / $SIGNATURE_TIME_INCREMENT)

    $hmac = [Security.Cryptography.HMACSHA1]::new([Text.Encoding]::ASCII.GetBytes($SIGNATURE_KEY + "`0"))

    for ($slot = 0; $slot -lt $Gamertag.Count; $slot++) {
        $account = [byte[]]::new($ACCOUNT_SIZE)
        $base    = $DATA_OFFSET + ($slot * $ACCOUNT_SIZE)

        [Array]::Copy([BitConverter]::GetBytes([uint64] (0x0009000000000001L + $slot)), 0, $account, 0, 8)
        Set-Ascii $account 12 16 $Gamertag[$slot]     # name
        Set-Ascii $account 28 12 'xbox.com'           # kingdom
        Set-Ascii $account 48 20 'xbox.com'           # domain
        Set-Ascii $account 68 24 'XBOX.COM'           # realm
        [Array]::Copy([BitConverter]::GetBytes($tick), 0, $account, 108, 4)

        $digest = $hmac.ComputeHash($account, 0, $SIGNATURE_OFFSET)
        [Array]::Copy($digest, 0, $account, $SIGNATURE_OFFSET, $SIGNATURE_SIZE)

        [Array]::Copy($account, 0, $sector, $base, $ACCOUNT_SIZE)
        "  slot {0}: {1,-16} xuid 0x{2:X16}" -f $slot, $Gamertag[$slot], (0x0009000000000001L + $slot)
    }

    [Array]::Copy([BitConverter]::GetBytes([uint32] $BEGIN_SIGNATURE), 0, $sector, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32] $CONFIG_VERSION), 0, $sector, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32] $CONFIG_SECTOR_COUNT), 0, $sector, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32] $END_SIGNATURE), 0, $sector, 508, 4)

    # The checksum is computed over the whole sector with its own field zeroed, then inverted.
    [Array]::Copy([BitConverter]::GetBytes([uint32] 0), 0, $sector, 504, 4)
    # -bnot would widen to a signed type here; over 32 bits the complement is this subtraction.
    $checksum = [uint32] (0xFFFFFFFFL - (Get-ConfigChecksum $sector))
    [Array]::Copy([BitConverter]::GetBytes([uint32] $checksum), 0, $sector, 504, 4)

    $stream.Position = $offset
    $stream.Write($sector, 0, $SECTOR_SIZE)

    "wrote {0} account(s) to config sector {1} at 0x{2:X}, checksum 0x{3:X8}" -f `
        $Gamertag.Count, $USER_ACCOUNT_SECTOR, $offset, $checksum
}
finally { $stream.Dispose() }
