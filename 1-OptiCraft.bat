@echo off

title OptiCraft 1.8.9

:: Local Route
cd /d "%~dp0"

:: Game Route
set MC_DIR=%CD%\mcdata

:: Options, World, Saves
set GAME_DIR="%MC_DIR%"

:: Runtimes DIR
set ASSETS_DIR="%MC_DIR%\assets"
set NATIVES_DIR="%MC_DIR%\natives"

:: Args
set GC=-XX:+UnlockExperimentalVMOptions -XX:+UnlockDiagnosticVMOptions -XX:+UseNUMA -XX:+AlwaysPreTouch -XX:+UseBiasedLocking -XX:+PerfDisableSharedMem -XX:+AggressiveOpts -XX:+UseFastAccessorMethods -XX:+UseXMMForArrayCopy -XX:+DisableExplicitGC -XX:+ParallelRefProcEnabled -XX:+UseConcMarkSweepGC -XX:-UseAdaptiveSizePolicy -XX:+CMSParallelRemarkEnabled -XX:+CMSClassUnloadingEnabled -XX:+UseCMSInitiatingOccupancyOnly -XX:ConcGCThreads=1 -XX:GCTimeRatio=99 -XX:ParallelGCThreads=2 -XX:+CMSScavengeBeforeRemark -XX:+TieredCompilation -XX:+UseFastJNIAccessors -XX:+CMSCleanOnEnter -XX:+UseThreadPriorities -XX:-UseGCOverheadLimit -Dfml.ignoreInvalidMinecraftCertificates=true -Dfml.ignorePatchDiscrepancies=true -Djava.net.useSystemProxies=true -XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump -Dsun.rmi.dgc.server.gcInterval=2147483646 -Djava.net.preferIPv4Stack=true -Dfml.ignorePatchDiscrepancies=true -Dfml.ignoreInvalidMinecraftCertificates=true 
set RAM=-Xms128M -Xmx1024M

:: Username 
set /p PLAYER_NAME=Username: 
IF [%PLAYER_NAME%] == [] set PLAYER_NAME=Steve

:: CD game route
cd /d "%~dp0\mcdata"

:: Start Game
start "" "runtime\bin\minecraft.exe" %RAM% %GC% -Djava.library.path=%NATIVES_DIR% -cp "%MC_DIR%\libraries\oshi-core.jar;%MC_DIR%\libraries\lwjgl.jar;%MC_DIR%\libraries\lwjgl-windows.jar;%MC_DIR%\libraries\lwjgl_util.jar;%MC_DIR%\libraries\commons-lang3.jar;%MC_DIR%\libraries\commons-compress.jar;%MC_DIR%\libraries\httpcore-4.3.2.jar;%MC_DIR%\libraries\optifine.jar;%MC_DIR%\libraries\launchwrapper.jar;%MC_DIR%\libraries\httpclient.jar;%MC_DIR%\libraries\log4j-core.jar;%MC_DIR%\libraries\log4j-api.jar;%MC_DIR%\libraries\commons-logging.jar;%MC_DIR%\libraries\jopt-simple.jar;%MC_DIR%\libraries\jutils.jar;%MC_DIR%\libraries\platform.jar;%MC_DIR%\libraries\jna.jar;%MC_DIR%\libraries\windows-plugin.jar;%MC_DIR%\libraries\jinput.jar;%MC_DIR%\libraries\commons-io.jar;%MC_DIR%\libraries\netty-all.jar;%MC_DIR%\libraries\gson.jar;%MC_DIR%\libraries\guava.jar;%MC_DIR%\libraries\libraryjavasound.jar;%MC_DIR%\libraries\soundsystem.jar;%MC_DIR%\libraries\codecjorbis.jar;%MC_DIR%\libraries\librarylwjglopenal.jar;%MC_DIR%\libraries\codecwav.jar;%MC_DIR%\libraries\authlib.jar;%MC_DIR%\libraries\icu4j-core-mojang.jar;%MC_DIR%\libraries\commons-codec.jar;%MC_DIR%\libraries\game.jar" net.minecraft.launchwrapper.Launch --username %PLAYER_NAME% --version 1.8.9 --accessToken [random] --userProperties {} --gameDir %GAME_DIR% --assetsDir %ASSETS_DIR% --assetIndex 1.8 --width 925 --height 530 --tweakClass optifine.OptiFineTweaker --uuid e4ff1ea62ec43e1ca0ceb206a0d472b5
