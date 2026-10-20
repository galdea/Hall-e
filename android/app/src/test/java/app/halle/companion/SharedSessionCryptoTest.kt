package app.halle.companion

import java.nio.charset.StandardCharsets
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SharedSessionCryptoTest {
    @Test
    fun decryptsTheSwiftSharedSessionWireVector() {
        val key = ByteArray(32)
        val encoded = "AAAAAAAAAAAAAAAAvc8hTygERh1iPba61Z2wbhcDd6VFxgi25C2u/QhM7kfVT5Mz6A=="

        assertArrayEquals(
            "shared-session-vector".toByteArray(StandardCharsets.UTF_8),
            SharedSessionCrypto.decrypt(encoded, key, "47f13ed1-11e1-4fb7-9c88-158084e94a4a"),
        )
    }

    @Test
    fun encryptsWithCombinedNonceAndAuthenticatesSessionId() {
        val key = ByteArray(32) { it.toByte() }
        val plaintext = """{"v":1,"title":"Planning"}""".toByteArray(StandardCharsets.UTF_8)

        val encoded = SharedSessionCrypto.encrypt(plaintext, key, SESSION_ID)
        val packed = Base64.getDecoder().decode(encoded)

        assertNotEquals(plaintext.toList(), packed.toList())
        assertArrayEquals(plaintext, SharedSessionCrypto.decrypt(encoded, key, SESSION_ID))
        assertThrows(Exception::class.java) {
            SharedSessionCrypto.decrypt(encoded, key, "00000000-0000-0000-0000-000000000002")
        }
    }

    companion object {
        private const val SESSION_ID = "00000000-0000-0000-0000-000000000001"
    }
}
