/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

package com.amazon.sample.ui.web.util;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import org.junit.jupiter.api.Test;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;

class AuthenticationAttributesControllerAdviceTest {

  private final AuthenticationAttributesControllerAdvice advice =
    new AuthenticationAttributesControllerAdvice(new ObjectMapper());

  @Test
  void authenticatedUsername_returnsEmailClaim() {
    var request = requestWithClaims(
      "{\"email\":\"agent@example.com\",\"username\":\"agent\"}"
    );

    assertThat(advice.authenticatedUsername(request)).isEqualTo(
      "agent@example.com"
    );
  }

  @Test
  void authenticatedUsername_fallsBackToUsernameClaim() {
    var request = requestWithClaims("{\"username\":\"agent\"}");

    assertThat(advice.authenticatedUsername(request)).isEqualTo("agent");
  }

  @Test
  void authenticatedUsername_returnsNullForInvalidHeader() {
    var request = MockServerHttpRequest.get("/")
      .header(AuthenticationAttributesControllerAdvice.OIDC_DATA_HEADER, "bad")
      .build();

    assertThat(advice.authenticatedUsername(request)).isNull();
  }

  private MockServerHttpRequest requestWithClaims(String claims) {
    String payload = Base64.getUrlEncoder()
      .withoutPadding()
      .encodeToString(claims.getBytes(StandardCharsets.UTF_8));
    String oidcData = "header." + payload + ".signature";

    return MockServerHttpRequest.get("/")
      .header(AuthenticationAttributesControllerAdvice.OIDC_DATA_HEADER, oidcData)
      .build();
  }
}
