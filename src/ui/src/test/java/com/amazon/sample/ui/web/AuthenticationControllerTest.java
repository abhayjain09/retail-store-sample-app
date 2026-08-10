/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 */

package com.amazon.sample.ui.web;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.mock.http.server.reactive.MockServerHttpResponse;

class AuthenticationControllerTest {

  @Test
  void logout_expiresAlbCookiesAndRedirectsToCognito() {
    String logoutUrl = "https://auth.example.com/logout?client_id=client";
    var controller = new AuthenticationController(
      logoutUrl,
      "retail-store-auth"
    );
    var response = new MockServerHttpResponse();

    controller.logout(response).block();

    assertThat(response.getStatusCode()).isEqualTo(HttpStatus.FOUND);
    assertThat(response.getHeaders().getLocation()).isEqualTo(
      URI.create(logoutUrl)
    );
    assertThat(response.getCookies()).containsKeys(
      "retail-store-auth",
      "retail-store-auth-0",
      "retail-store-auth-1",
      "retail-store-auth-2",
      "retail-store-auth-3"
    );
    assertThat(
      response.getCookies().getFirst("retail-store-auth").getMaxAge()
    ).isEqualTo(Duration.ZERO);
  }
}
