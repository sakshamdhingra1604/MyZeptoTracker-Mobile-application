@rem
@rem Gradle startup script for Windows (standard wrapper)
@rem
@if "%DEBUG%"=="" @echo off

@rem Set local scope for the variables with windows NT shell
if "%OS%"=="Windows_NT" setlocal

set DIRNAME=%~dp0
if "%DIRNAME%"=="" set DIRNAME=.
@rem This is normally unused
set APP_BASE_NAME=%~n0
set APP_HOME=%DIRNAME%

@rem Resolve any "." and ".." in APP_HOME to make it shorter.
for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi

set WRAPPER_JAR=%APP_HOME%\gradle\wrapper\gradle-wrapper.jar

@rem Use JAVA_HOME if set; otherwise fall back to java on PATH
set JAVA_EXE=java.exe
if defined JAVA_HOME (
    set JAVA_EXE=%JAVA_HOME%\bin\java.exe
    if not exist "%JAVA_HOME%\bin\java.exe" (
        echo ERROR: JAVA_HOME is set to an invalid directory: %JAVA_HOME%
        echo Please set JAVA_HOME to a valid JDK installation.
        exit /b 1
    )
)

@rem Execute Gradle
"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %GRADLE_OPTS% ^
  "-Dorg.gradle.appname=%APP_BASE_NAME%" ^
  -classpath "%WRAPPER_JAR%" ^
  org.gradle.wrapper.GradleWrapperMain %*

if "%OS%"=="Windows_NT" endlocal

exit /b %ERRORLEVEL%
